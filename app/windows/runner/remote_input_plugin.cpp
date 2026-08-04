#include "remote_input_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <gdiplus.h>
#include <objidl.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

namespace {

constexpr char kChannelName[] = "privet/remote_input";

bool IsSecureDesktopActive() {
  // UAC / secure desktop — refuse injection.
  DWORD session_id = 0;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session_id)) {
    return false;
  }
  // Heuristic: GetForegroundWindow fails / is null on secure desktop more often;
  // also check input desktop name.
  HDESK desk = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desk) {
    return true;
  }
  wchar_t name[256] = {};
  DWORD needed = 0;
  bool secure = false;
  if (GetUserObjectInformationW(desk, UOI_NAME, name, sizeof(name), &needed)) {
    // Default desktop is "Default"; Winlogon/UAC use other names.
    if (_wcsicmp(name, L"Default") != 0) {
      secure = true;
    }
  }
  CloseDesktop(desk);
  return secure;
}

void AbsoluteMove(int x, int y) {
  const int origin_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int origin_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int screen_w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int screen_h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (screen_w <= 1 || screen_h <= 1) return;
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dx =
      static_cast<LONG>(((x - origin_x) * 65535ll) / (screen_w - 1));
  input.mi.dy =
      static_cast<LONG>(((y - origin_y) * 65535ll) / (screen_h - 1));
  input.mi.dwFlags =
      MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  SendInput(1, &input, sizeof(INPUT));
}

int ClampPixel(double norm, int extent) {
  if (extent <= 1) return 0;
  if (norm < 0) norm = 0;
  if (norm > 1) norm = 1;
  return static_cast<int>(norm * (extent - 1) + 0.5);
}

DWORD ButtonDownFlag(int button) {
  switch (button) {
    case 2:
      return MOUSEEVENTF_RIGHTDOWN;
    case 4:
      return MOUSEEVENTF_MIDDLEDOWN;
    default:
      return MOUSEEVENTF_LEFTDOWN;
  }
}

DWORD ButtonUpFlag(int button) {
  switch (button) {
    case 2:
      return MOUSEEVENTF_RIGHTUP;
    case 4:
      return MOUSEEVENTF_MIDDLEUP;
    default:
      return MOUSEEVENTF_LEFTUP;
  }
}

WORD VkFromCode(std::string code) {
  code.erase(std::remove(code.begin(), code.end(), ' '), code.end());
  static const struct {
    const char* code;
    WORD vk;
  } kMap[] = {
      {"KeyA", 'A'}, {"KeyB", 'B'}, {"KeyC", 'C'}, {"KeyD", 'D'},
      {"KeyE", 'E'}, {"KeyF", 'F'}, {"KeyG", 'G'}, {"KeyH", 'H'},
      {"KeyI", 'I'}, {"KeyJ", 'J'}, {"KeyK", 'K'}, {"KeyL", 'L'},
      {"KeyM", 'M'}, {"KeyN", 'N'}, {"KeyO", 'O'}, {"KeyP", 'P'},
      {"KeyQ", 'Q'}, {"KeyR", 'R'}, {"KeyS", 'S'}, {"KeyT", 'T'},
      {"KeyU", 'U'}, {"KeyV", 'V'}, {"KeyW", 'W'}, {"KeyX", 'X'},
      {"KeyY", 'Y'}, {"KeyZ", 'Z'},
      {"Digit0", '0'}, {"Digit1", '1'}, {"Digit2", '2'}, {"Digit3", '3'},
      {"Digit4", '4'}, {"Digit5", '5'}, {"Digit6", '6'}, {"Digit7", '7'},
      {"Digit8", '8'}, {"Digit9", '9'},
      {"Enter", VK_RETURN}, {"NumpadEnter", VK_RETURN},
      {"Escape", VK_ESCAPE}, {"Backspace", VK_BACK}, {"Tab", VK_TAB},
      {"Space", VK_SPACE}, {"Delete", VK_DELETE}, {"Insert", VK_INSERT},
      {"Home", VK_HOME}, {"End", VK_END}, {"PageUp", VK_PRIOR},
      {"PageDown", VK_NEXT},
      {"ArrowLeft", VK_LEFT}, {"ArrowRight", VK_RIGHT},
      {"ArrowUp", VK_UP}, {"ArrowDown", VK_DOWN},
      {"ShiftLeft", VK_LSHIFT}, {"ShiftRight", VK_RSHIFT},
      {"ControlLeft", VK_LCONTROL}, {"ControlRight", VK_RCONTROL},
      {"AltLeft", VK_LMENU}, {"AltRight", VK_RMENU},
      {"MetaLeft", VK_LWIN}, {"MetaRight", VK_RWIN},
      {"OSLeft", VK_LWIN}, {"OSRight", VK_RWIN},
      {"F1", VK_F1}, {"F2", VK_F2}, {"F3", VK_F3}, {"F4", VK_F4},
      {"F5", VK_F5}, {"F6", VK_F6}, {"F7", VK_F7}, {"F8", VK_F8},
      {"F9", VK_F9}, {"F10", VK_F10}, {"F11", VK_F11}, {"F12", VK_F12},
      {"Minus", VK_OEM_MINUS}, {"Equal", VK_OEM_PLUS},
      {"BracketLeft", VK_OEM_4}, {"BracketRight", VK_OEM_6},
      {"Backslash", VK_OEM_5}, {"Semicolon", VK_OEM_1},
      {"Quote", VK_OEM_7}, {"Comma", VK_OEM_COMMA}, {"Period", VK_OEM_PERIOD},
      {"Slash", VK_OEM_2}, {"Backquote", VK_OEM_3},
  };
  for (const auto& e : kMap) {
    if (code == e.code) return e.vk;
  }
  return 0;
}

std::unordered_set<WORD> g_down_keys;

void SendVk(WORD vk, bool down) {
  if (!vk) return;
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
  SendInput(1, &input, sizeof(INPUT));
  if (down) {
    g_down_keys.insert(vk);
  } else {
    g_down_keys.erase(vk);
  }
}

void ReleaseAllKeys() {
  for (WORD vk : g_down_keys) {
    INPUT input = {};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vk;
    input.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, &input, sizeof(INPUT));
  }
  g_down_keys.clear();
  // Also lift mouse buttons.
  INPUT ups[3] = {};
  ups[0].type = INPUT_MOUSE;
  ups[0].mi.dwFlags = MOUSEEVENTF_LEFTUP;
  ups[1].type = INPUT_MOUSE;
  ups[1].mi.dwFlags = MOUSEEVENTF_RIGHTUP;
  ups[2].type = INPUT_MOUSE;
  ups[2].mi.dwFlags = MOUSEEVENTF_MIDDLEUP;
  SendInput(3, ups, sizeof(INPUT));
}

ULONG_PTR g_gdiplus_token = 0;

struct GdiplusInitializer {
  GdiplusInitializer() {
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr);
  }
  ~GdiplusInitializer() {
    if (g_gdiplus_token) {
      Gdiplus::GdiplusShutdown(g_gdiplus_token);
    }
  }
} g_gdiplus_init;

int PngEncoderClsid(CLSID* clsid) {
  UINT num = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;
  std::vector<BYTE> buffer(size);
  auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  Gdiplus::GetImageEncoders(num, size, codecs);
  for (UINT i = 0; i < num; ++i) {
    if (wcscmp(codecs[i].MimeType, L"image/png") == 0) {
      *clsid = codecs[i].Clsid;
      return static_cast<int>(i);
    }
  }
  return -1;
}

std::vector<uint8_t> BitmapToPng(Gdiplus::Bitmap* bitmap) {
  std::vector<uint8_t> result;
  if (!bitmap || bitmap->GetLastStatus() != Gdiplus::Ok) {
    return result;
  }
  CLSID clsid = {};
  if (PngEncoderClsid(&clsid) < 0) {
    return result;
  }
  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK) {
    return result;
  }
  if (bitmap->Save(stream, &clsid) == Gdiplus::Ok) {
    HGLOBAL hg = nullptr;
    if (GetHGlobalFromStream(stream, &hg) == S_OK) {
      const SIZE_T size = GlobalSize(hg);
      auto* data = static_cast<uint8_t*>(GlobalLock(hg));
      if (data && size > 0) {
        result.assign(data, data + size);
      }
      GlobalUnlock(hg);
    }
  }
  stream->Release();
  return result;
}

std::vector<uint8_t> PngFromDib(const void* dib_data) {
  auto* bih = static_cast<const BITMAPINFOHEADER*>(dib_data);
  if (!bih || bih->biSize < sizeof(BITMAPINFOHEADER)) {
    return {};
  }

  DWORD palette_size = 0;
  if (bih->biCompression == BI_RGB) {
    if (bih->biBitCount <= 8) {
      const DWORD colors =
          bih->biClrUsed ? bih->biClrUsed : (1u << bih->biBitCount);
      palette_size = colors * sizeof(RGBQUAD);
    }
  } else if (bih->biCompression == BI_BITFIELDS) {
    palette_size = 3 * sizeof(DWORD);
  }

  const auto* bits = static_cast<const BYTE*>(dib_data) + bih->biSize +
                     palette_size;
  std::unique_ptr<Gdiplus::Bitmap> bitmap(Gdiplus::Bitmap::FromBITMAPINFO(
      reinterpret_cast<const BITMAPINFO*>(dib_data),
      const_cast<BYTE*>(bits)));
  return BitmapToPng(bitmap.get());
}

std::vector<uint8_t> ReadClipboardImagePng() {
  std::vector<uint8_t> result;
  if (!OpenClipboard(nullptr)) {
    return result;
  }

  const UINT png_fmt = RegisterClipboardFormatW(L"PNG");
  if (png_fmt != 0 && IsClipboardFormatAvailable(png_fmt)) {
    HANDLE data = GetClipboardData(png_fmt);
    if (data) {
      auto* ptr = static_cast<const uint8_t*>(GlobalLock(data));
      const SIZE_T size = GlobalSize(data);
      if (ptr && size > 0) {
        result.assign(ptr, ptr + size);
      }
      GlobalUnlock(data);
    }
    CloseClipboard();
    return result;
  }

  if (IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE data = GetClipboardData(CF_DIB);
    if (data) {
      void* locked = GlobalLock(data);
      if (locked) {
        result = PngFromDib(locked);
        GlobalUnlock(data);
      }
    }
  } else if (IsClipboardFormatAvailable(CF_BITMAP)) {
    HBITMAP hbm = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
    if (hbm) {
      std::unique_ptr<Gdiplus::Bitmap> bitmap(
          Gdiplus::Bitmap::FromHBITMAP(hbm, nullptr));
      result = BitmapToPng(bitmap.get());
    }
  }

  CloseClipboard();
  return result;
}

void HandleMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "probe") {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("canInject")] = flutter::EncodableValue(true);
    map[flutter::EncodableValue("platform")] =
        flutter::EncodableValue("windows");
    map[flutter::EncodableValue("backend")] =
        flutter::EncodableValue("SendInput");
    map[flutter::EncodableValue("detail")] = flutter::EncodableValue("");
    result->Success(flutter::EncodableValue(map));
    return;
  }

  if (call.method_name() == "ensureReady") {
    if (IsSecureDesktopActive()) {
      result->Error("secure_desktop",
                    "Input blocked while a secure desktop (UAC) is active.");
      return;
    }
    result->Success();
    return;
  }

  if (IsSecureDesktopActive()) {
    result->Error("secure_desktop",
                  "Input blocked while a secure desktop (UAC) is active.");
    return;
  }

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  auto num = [&](const char* key, double fallback = 0) -> double {
    if (!args) return fallback;
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return fallback;
    if (const auto* d = std::get_if<double>(&it->second)) return *d;
    if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
    if (const auto* i64 = std::get_if<int64_t>(&it->second))
      return static_cast<double>(*i64);
    return fallback;
  };
  auto integer = [&](const char* key, int fallback = 0) -> int {
    return static_cast<int>(num(key, fallback));
  };
  auto boolean = [&](const char* key, bool fallback = false) -> bool {
    if (!args) return fallback;
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return fallback;
    if (const auto* b = std::get_if<bool>(&it->second)) return *b;
    return fallback;
  };
  auto str = [&](const char* key) -> std::string {
    if (!args) return {};
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return {};
    if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
    return {};
  };

  if (call.method_name() == "pointerMove") {
    const int w = integer("w", GetSystemMetrics(SM_CXSCREEN));
    const int h = integer("h", GetSystemMetrics(SM_CYSCREEN));
    AbsoluteMove(ClampPixel(num("x"), w), ClampPixel(num("y"), h));
    result->Success();
    return;
  }

  if (call.method_name() == "pointerButton") {
    const int w = integer("w", GetSystemMetrics(SM_CXSCREEN));
    const int h = integer("h", GetSystemMetrics(SM_CYSCREEN));
    AbsoluteMove(ClampPixel(num("x"), w), ClampPixel(num("y"), h));
    const int button = integer("button", 1);
    const bool down = boolean("down", false);
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = down ? ButtonDownFlag(button) : ButtonUpFlag(button);
    SendInput(1, &input, sizeof(INPUT));
    result->Success();
    return;
  }

  if (call.method_name() == "wheel") {
    const int w = integer("w", GetSystemMetrics(SM_CXSCREEN));
    const int h = integer("h", GetSystemMetrics(SM_CYSCREEN));
    AbsoluteMove(ClampPixel(num("x"), w), ClampPixel(num("y"), h));
    const int dy = static_cast<int>(-num("dy"));
    const int dx = static_cast<int>(num("dx"));
    if (dy != 0) {
      INPUT input = {};
      input.type = INPUT_MOUSE;
      input.mi.dwFlags = MOUSEEVENTF_WHEEL;
      input.mi.mouseData = static_cast<DWORD>(dy);
      SendInput(1, &input, sizeof(INPUT));
    }
    if (dx != 0) {
      INPUT input = {};
      input.type = INPUT_MOUSE;
      input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
      input.mi.mouseData = static_cast<DWORD>(dx);
      SendInput(1, &input, sizeof(INPUT));
    }
    result->Success();
    return;
  }

  if (call.method_name() == "keyEvent") {
    const std::string code = str("code");
    const bool down = boolean("down", false);
    WORD vk = VkFromCode(code);
    if (!vk && code.size() == 1) {
      SHORT mapped = VkKeyScanA(code[0]);
      if (mapped != -1) vk = LOBYTE(mapped);
    }
    if (!vk) {
      const std::string key = str("key");
      if (key.size() == 1) {
        SHORT mapped = VkKeyScanA(key[0]);
        if (mapped != -1) vk = LOBYTE(mapped);
      }
    }
    SendVk(vk, down);
    result->Success();
    return;
  }

  if (call.method_name() == "releaseAll") {
    ReleaseAllKeys();
    result->Success();
    return;
  }

  if (call.method_name() == "getClipboardText") {
    std::string text;
    if (OpenClipboard(nullptr)) {
      HANDLE data = GetClipboardData(CF_UNICODETEXT);
      if (data) {
        auto* locked = static_cast<wchar_t*>(GlobalLock(data));
        if (locked) {
          int bytes = WideCharToMultiByte(CP_UTF8, 0, locked, -1, nullptr, 0,
                                          nullptr, nullptr);
          if (bytes > 1) {
            text.resize(bytes - 1);
            WideCharToMultiByte(CP_UTF8, 0, locked, -1, text.data(), bytes,
                                nullptr, nullptr);
          }
          GlobalUnlock(data);
        }
      }
      CloseClipboard();
    }
    result->Success(flutter::EncodableValue(text));
    return;
  }

  if (call.method_name() == "setClipboardText") {
    const std::string text = str("text");
    if (OpenClipboard(nullptr)) {
      EmptyClipboard();
      int wlen = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
      if (wlen > 0) {
        HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, wlen * sizeof(wchar_t));
        if (mem) {
          auto* locked = static_cast<wchar_t*>(GlobalLock(mem));
          if (locked) {
            MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, locked, wlen);
            GlobalUnlock(mem);
            SetClipboardData(CF_UNICODETEXT, mem);
          }
        }
      }
      CloseClipboard();
    }
    result->Success();
    return;
  }

  if (call.method_name() == "getClipboardImagePng") {
    std::vector<uint8_t> png = ReadClipboardImagePng();
    if (png.empty()) {
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(png));
    return;
  }

  if (call.method_name() == "setInputLock") {
    // BlockInput() would also block Privet's Ctrl+Shift+Esc escape hatch.
    // Report unlocked; UI still shows "take back" and revoke still works.
    (void)boolean("locked", false);
    result->Success(flutter::EncodableValue(false));
    return;
  }

  result->NotImplemented();
}

}  // namespace

void RegisterRemoteInputPlugin(flutter::FlutterViewController* controller) {
  if (!controller || !controller->engine()) return;
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          controller->engine()->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) { HandleMethod(call, std::move(result)); });
  // Keep channel alive for process lifetime.
  static auto retained = std::move(channel);
}
