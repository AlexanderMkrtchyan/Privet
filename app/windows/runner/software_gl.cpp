#include "software_gl.h"

#include <d3d11.h>
#include <dxgi.h>
#include <windows.h>

#include <cstring>

namespace {

constexpr int kEglNone = 0x3038;
constexpr int kAngleDeviceType = 0x3209;
constexpr int kAngleDeviceWarp = 0x320B;
constexpr UINT kMicrosoftVendorId = 0x1414;

using EglGetProcAddressFn = void*(__stdcall*)(const char* name);
using EglGetPlatformDisplayFn = void*(__stdcall*)(int platform,
                                                  void* native_display,
                                                  const int* attribs);
using D3D11CreateDeviceFn = HRESULT(WINAPI*)(
    IDXGIAdapter* adapter, D3D_DRIVER_TYPE driver_type, HMODULE software,
    UINT flags, const D3D_FEATURE_LEVEL* feature_levels, UINT feature_level_count,
    UINT sdk_version, ID3D11Device** device, D3D_FEATURE_LEVEL* feature_level,
    ID3D11DeviceContext** context);
using Win32GetProcAddressFn = FARPROC(WINAPI*)(HMODULE module, LPCSTR name);

EglGetProcAddressFn g_real_egl_get_proc = nullptr;
EglGetPlatformDisplayFn g_real_platform_display = nullptr;
D3D11CreateDeviceFn g_real_d3d11_create_device = nullptr;
Win32GetProcAddressFn g_real_get_proc_address = nullptr;
int g_attrib_buf[64];

HRESULT WINAPI HookedD3D11CreateDevice(
    IDXGIAdapter* adapter, D3D_DRIVER_TYPE driver_type, HMODULE software,
    UINT flags, const D3D_FEATURE_LEVEL* feature_levels, UINT feature_level_count,
    UINT sdk_version, ID3D11Device** device, D3D_FEATURE_LEVEL* feature_level,
    ID3D11DeviceContext** context) {
  // WARP is the software device shipped with Windows. The adapter argument
  // must be null when the driver type is WARP.
  (void)adapter;
  (void)driver_type;
  (void)software;
  return g_real_d3d11_create_device(
      nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, feature_levels,
      feature_level_count, sdk_version, device, feature_level, context);
}

void* __stdcall HookedGetPlatformDisplay(int platform,
                                         void* native_display,
                                         const int* attribs) {
  int count = 0;
  bool has_device = false;
  if (attribs != nullptr) {
    for (int i = 0; attribs[i] != kEglNone && count < 60; i += 2) {
      if (attribs[i] == kAngleDeviceType) {
        has_device = true;
      }
      g_attrib_buf[count++] = attribs[i];
      g_attrib_buf[count++] = attribs[i + 1];
    }
  }
  if (!has_device && count < 60) {
    g_attrib_buf[count++] = kAngleDeviceType;
    g_attrib_buf[count++] = kAngleDeviceWarp;
  }
  g_attrib_buf[count] = kEglNone;
  return g_real_platform_display(platform, native_display, g_attrib_buf);
}

void* __stdcall HookedEglGetProcAddress(const char* name) {
  void* proc = g_real_egl_get_proc(name);
  if (name != nullptr &&
      std::strcmp(name, "eglGetPlatformDisplayEXT") == 0 && proc != nullptr) {
    g_real_platform_display = reinterpret_cast<EglGetPlatformDisplayFn>(proc);
    return reinterpret_cast<void*>(&HookedGetPlatformDisplay);
  }
  return proc;
}

FARPROC WINAPI HookedWin32GetProcAddress(HMODULE module, LPCSTR name) {
  FARPROC proc = g_real_get_proc_address(module, name);
  if (name == nullptr || proc == nullptr) {
    return proc;
  }
  // Ordinal lookups pass a small integer, not a string.
  if (reinterpret_cast<ULONG_PTR>(name) <= 0xFFFF) {
    return proc;
  }
  if (std::strcmp(name, "D3D11CreateDevice") == 0) {
    if (g_real_d3d11_create_device == nullptr) {
      g_real_d3d11_create_device = reinterpret_cast<D3D11CreateDeviceFn>(proc);
    }
    return reinterpret_cast<FARPROC>(&HookedD3D11CreateDevice);
  }
  if (std::strcmp(name, "eglGetProcAddress") == 0) {
    if (g_real_egl_get_proc == nullptr) {
      g_real_egl_get_proc = reinterpret_cast<EglGetProcAddressFn>(proc);
    }
    return reinterpret_cast<FARPROC>(&HookedEglGetProcAddress);
  }
  return proc;
}

struct HookTarget {
  const char* import_name;
  void* replacement;
  void** original;
};

bool PatchThunk(void** slot, void* replacement, void** original) {
  DWORD old_protect = 0;
  if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old_protect)) {
    return false;
  }
  if (original != nullptr && *original == nullptr) {
    *original = *slot;
  }
  *slot = replacement;
  VirtualProtect(slot, sizeof(void*), old_protect, &old_protect);
  return true;
}

bool TryPatchName(IMAGE_THUNK_DATA* names, IMAGE_THUNK_DATA* thunks,
                  BYTE* base, const HookTarget& target) {
  for (; names->u1.AddressOfData != 0; ++names, ++thunks) {
    if (names->u1.Ordinal & IMAGE_ORDINAL_FLAG) {
      continue;
    }
    auto* import_name = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(
        base + names->u1.AddressOfData);
    if (std::strcmp(import_name->Name, target.import_name) != 0) {
      continue;
    }
    return PatchThunk(reinterpret_cast<void**>(&thunks->u1.Function),
                      target.replacement, target.original);
  }
  return false;
}

void PatchModule(HMODULE module, const HookTarget* targets, int target_count) {
  if (module == nullptr) {
    return;
  }
  auto* base = reinterpret_cast<BYTE*>(module);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
    return;
  }
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE) {
    return;
  }
  const auto& dir =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (dir.VirtualAddress == 0) {
    return;
  }
  auto* import_desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(
      base + dir.VirtualAddress);
  for (; import_desc->Name != 0; ++import_desc) {
    if (import_desc->OriginalFirstThunk == 0) {
      continue;
    }
    auto* names = reinterpret_cast<IMAGE_THUNK_DATA*>(
        base + import_desc->OriginalFirstThunk);
    auto* thunks = reinterpret_cast<IMAGE_THUNK_DATA*>(
        base + import_desc->FirstThunk);
    for (int i = 0; i < target_count; ++i) {
      TryPatchName(names, thunks, base, targets[i]);
    }
  }

  const auto& delay =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
  if (delay.VirtualAddress == 0) {
    return;
  }
  auto* delay_desc = reinterpret_cast<IMAGE_DELAYLOAD_DESCRIPTOR*>(
      base + delay.VirtualAddress);
  for (; delay_desc->DllNameRVA != 0; ++delay_desc) {
    auto* names = reinterpret_cast<IMAGE_THUNK_DATA*>(
        base + delay_desc->ImportNameTableRVA);
    auto* thunks = reinterpret_cast<IMAGE_THUNK_DATA*>(
        base + delay_desc->ImportAddressTableRVA);
    for (int i = 0; i < target_count; ++i) {
      TryPatchName(names, thunks, base, targets[i]);
    }
  }
}

HMODULE LoadBesideExe(const wchar_t* filename) {
  wchar_t path[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return nullptr;
  }
  wchar_t* slash = wcsrchr(path, L'\\');
  if (slash == nullptr) {
    return nullptr;
  }
  *(slash + 1) = L'\0';
  wcscat_s(path, filename);
  return LoadLibraryW(path);
}

bool EqualsIgnoreCase(const wchar_t* a, const wchar_t* b) {
  while (*a != L'\0' && *b != L'\0') {
    wchar_t ca = *a;
    wchar_t cb = *b;
    if (ca >= L'A' && ca <= L'Z') {
      ca = static_cast<wchar_t>(ca - L'A' + L'a');
    }
    if (cb >= L'A' && cb <= L'Z') {
      cb = static_cast<wchar_t>(cb - L'A' + L'a');
    }
    if (ca != cb) {
      return false;
    }
    ++a;
    ++b;
  }
  return *a == *b;
}

bool AdapterIsHardware(const DXGI_ADAPTER_DESC1& desc) {
  if ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) {
    return false;
  }
  if (desc.VendorId == kMicrosoftVendorId) {
    return false;
  }
  return true;
}

bool AdapterSupportsFeatureLevel11(IDXGIAdapter1* adapter) {
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  const D3D_FEATURE_LEVEL requested[] = {D3D_FEATURE_LEVEL_11_0};
  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  const HRESULT hr = D3D11CreateDevice(
      adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, requested,
      static_cast<UINT>(sizeof(requested) / sizeof(requested[0])),
      D3D11_SDK_VERSION, &device, &level, &context);
  if (context != nullptr) {
    context->Release();
  }
  if (device != nullptr) {
    device->Release();
  }
  return SUCCEEDED(hr) && level >= D3D_FEATURE_LEVEL_11_0;
}

BOOL CALLBACK CloseHungWindow(HWND hwnd, LPARAM param) {
  auto* self = reinterpret_cast<DWORD*>(param);
  wchar_t class_name[64];
  if (GetClassNameW(hwnd, class_name, 64) == 0) {
    return TRUE;
  }
  if (wcscmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) {
    return TRUE;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0 || pid == *self) {
    return TRUE;
  }
  DWORD_PTR result = 0;
  const LRESULT answered = SendMessageTimeoutW(
      hwnd, WM_NULL, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 1500, &result);
  if (answered != 0 && !IsHungAppWindow(hwnd)) {
    return TRUE;
  }
  // Every Flutter Windows app uses this window class. Only stop Privet.
  HANDLE process = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, FALSE, pid);
  if (process == nullptr) {
    return TRUE;
  }
  wchar_t image[MAX_PATH];
  DWORD image_length = MAX_PATH;
  const BOOL named =
      QueryFullProcessImageNameW(process, 0, image, &image_length);
  const wchar_t* file = named ? wcsrchr(image, L'\\') : nullptr;
  file = file != nullptr ? file + 1 : image;
  if (named && EqualsIgnoreCase(file, L"privet.exe")) {
    TerminateProcess(process, 1);
  }
  CloseHandle(process);
  return TRUE;
}

}  // namespace

bool PrivetNeedsSoftwareGl() {
  IDXGIFactory1* factory = nullptr;
  const HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(hr) || factory == nullptr) {
    return true;
  }
  bool safe = false;
  IDXGIAdapter1* adapter = nullptr;
  for (UINT index = 0;
       factory->EnumAdapters1(index, &adapter) != DXGI_ERROR_NOT_FOUND;
       ++index) {
    DXGI_ADAPTER_DESC1 desc = {};
    if (SUCCEEDED(adapter->GetDesc1(&desc)) && AdapterIsHardware(desc) &&
        AdapterSupportsFeatureLevel11(adapter)) {
      safe = true;
    }
    adapter->Release();
    adapter = nullptr;
    if (safe) {
      break;
    }
  }
  factory->Release();
  return !safe;
}

bool PrivetCommandLineHasSoftwareGl() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  bool found = false;
  for (int i = 1; i < argc; ++i) {
    if (wcscmp(argv[i], L"--privet-software-gl") == 0) {
      found = true;
      break;
    }
  }
  LocalFree(argv);
  return found;
}

void PrivetInstallSoftwareGlHook() {
  // Resolve the real exports before any import is patched. Saving the IAT
  // slot instead can capture a delay-load stub and recurse back into the hook.
  HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
  if (kernel32 != nullptr) {
    g_real_get_proc_address = reinterpret_cast<Win32GetProcAddressFn>(
        GetProcAddress(kernel32, "GetProcAddress"));
  }
  HMODULE d3d11 = LoadLibraryW(L"d3d11.dll");
  if (d3d11 != nullptr && g_real_get_proc_address != nullptr) {
    g_real_d3d11_create_device = reinterpret_cast<D3D11CreateDeviceFn>(
        g_real_get_proc_address(d3d11, "D3D11CreateDevice"));
  }

  // libEGL / libGLESv2 may not be mapped until Flutter starts. Load them from
  // the install directory so their Direct3D imports can be redirected first.
  LoadBesideExe(L"flutter_windows.dll");
  HMODULE egl = LoadBesideExe(L"libEGL.dll");
  LoadBesideExe(L"libGLESv2.dll");
  if (egl != nullptr && g_real_get_proc_address != nullptr) {
    g_real_egl_get_proc = reinterpret_cast<EglGetProcAddressFn>(
        g_real_get_proc_address(egl, "eglGetProcAddress"));
  }

  HookTarget targets[3];
  int target_count = 0;
  if (g_real_get_proc_address != nullptr) {
    targets[target_count++] = {
        "GetProcAddress",
        reinterpret_cast<void*>(&HookedWin32GetProcAddress), nullptr};
  }
  if (g_real_d3d11_create_device != nullptr) {
    targets[target_count++] = {
        "D3D11CreateDevice",
        reinterpret_cast<void*>(&HookedD3D11CreateDevice), nullptr};
  }
  if (g_real_egl_get_proc != nullptr) {
    targets[target_count++] = {
        "eglGetProcAddress", reinterpret_cast<void*>(&HookedEglGetProcAddress),
        nullptr};
  }
  if (target_count == 0) {
    return;
  }
  const HMODULE modules[] = {
      GetModuleHandleW(L"flutter_windows.dll"),
      GetModuleHandleW(L"libEGL.dll"),
      GetModuleHandleW(L"libGLESv2.dll"),
  };
  for (HMODULE module : modules) {
    PatchModule(module, targets, target_count);
  }
}

void PrivetCloseHungWindows() {
  DWORD self = GetCurrentProcessId();
  EnumWindows(CloseHungWindow, reinterpret_cast<LPARAM>(&self));
}

void PrivetRelaunchSoftwareGl() {
  wchar_t command[32768];
  wcscpy_s(command, GetCommandLineW());
  if (wcsstr(command, L"--privet-software-gl") == nullptr) {
    wcscat_s(command, L" --privet-software-gl");
  }
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  CreateProcessW(nullptr, command, nullptr, nullptr, FALSE, 0, nullptr,
                 nullptr, &startup, &process);
  if (process.hThread != nullptr) {
    CloseHandle(process.hThread);
  }
  if (process.hProcess != nullptr) {
    CloseHandle(process.hProcess);
  }
  ExitProcess(1);
}
