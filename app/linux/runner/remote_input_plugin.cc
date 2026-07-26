#include "remote_input_plugin.h"

#include <gdk/gdk.h>
#include <gio/gio.h>
#include <gtk/gtk.h>

#ifdef GDK_WINDOWING_X11
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <gdk/gdkx.h>
#endif

#include <cstring>
#include <string>
#include <unordered_set>

namespace {

constexpr const char* kChannelName = "privet/remote_input";

enum class Backend { Unavailable, X11, Portal };

Backend g_backend = Backend::Unavailable;
std::string g_detail;

GDBusProxy* g_portal_proxy = nullptr;
std::string g_session_path;
bool g_portal_ready = false;

std::unordered_set<guint> g_down_keys;

struct PortalWait {
  bool done = false;
  guint32 code = 2;
  GVariant* results = nullptr;
};

int ClampPixel(double norm, int extent) {
  if (extent <= 1) return 0;
  if (norm < 0) norm = 0;
  if (norm > 1) norm = 1;
  return static_cast<int>(norm * (extent - 1) + 0.5);
}

bool IsX11Display() {
#ifdef GDK_WINDOWING_X11
  GdkDisplay* display = gdk_display_get_default();
  return display && GDK_IS_X11_DISPLAY(display);
#else
  return false;
#endif
}

bool IsWaylandDisplay() {
  const char* session = g_getenv("XDG_SESSION_TYPE");
  if (session && g_ascii_strcasecmp(session, "wayland") == 0) return true;
  GdkDisplay* display = gdk_display_get_default();
  if (!display) return false;
  const char* name = gdk_display_get_name(display);
  return name && std::strstr(name, "wayland") != nullptr;
}

#ifdef GDK_WINDOWING_X11
Display* XDisplayOrNull() {
  GdkDisplay* gd = gdk_display_get_default();
  if (!gd || !GDK_IS_X11_DISPLAY(gd)) return nullptr;
  return gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(gd));
}
#endif

guint KeyvalFromCode(const std::string& code) {
  static const struct {
    const char* code;
    const char* name;
  } kMap[] = {
      {"KeyA", "a"}, {"KeyB", "b"}, {"KeyC", "c"}, {"KeyD", "d"},
      {"KeyE", "e"}, {"KeyF", "f"}, {"KeyG", "g"}, {"KeyH", "h"},
      {"KeyI", "i"}, {"KeyJ", "j"}, {"KeyK", "k"}, {"KeyL", "l"},
      {"KeyM", "m"}, {"KeyN", "n"}, {"KeyO", "o"}, {"KeyP", "p"},
      {"KeyQ", "q"}, {"KeyR", "r"}, {"KeyS", "s"}, {"KeyT", "t"},
      {"KeyU", "u"}, {"KeyV", "v"}, {"KeyW", "w"}, {"KeyX", "x"},
      {"KeyY", "y"}, {"KeyZ", "z"},
      {"Digit0", "0"}, {"Digit1", "1"}, {"Digit2", "2"}, {"Digit3", "3"},
      {"Digit4", "4"}, {"Digit5", "5"}, {"Digit6", "6"}, {"Digit7", "7"},
      {"Digit8", "8"}, {"Digit9", "9"},
      {"Enter", "Return"}, {"Escape", "Escape"}, {"Backspace", "BackSpace"},
      {"Tab", "Tab"}, {"Space", "space"}, {"Delete", "Delete"},
      {"Insert", "Insert"}, {"Home", "Home"}, {"End", "End"},
      {"PageUp", "Page_Up"}, {"PageDown", "Page_Down"},
      {"ArrowLeft", "Left"}, {"ArrowRight", "Right"},
      {"ArrowUp", "Up"}, {"ArrowDown", "Down"},
      {"ShiftLeft", "Shift_L"}, {"ShiftRight", "Shift_R"},
      {"ControlLeft", "Control_L"}, {"ControlRight", "Control_R"},
      {"AltLeft", "Alt_L"}, {"AltRight", "Alt_R"},
      {"F1", "F1"}, {"F2", "F2"}, {"F3", "F3"}, {"F4", "F4"},
      {"F5", "F5"}, {"F6", "F6"}, {"F7", "F7"}, {"F8", "F8"},
      {"F9", "F9"}, {"F10", "F10"}, {"F11", "F11"}, {"F12", "F12"},
      {"Minus", "minus"}, {"Equal", "equal"},
      {"BracketLeft", "bracketleft"}, {"BracketRight", "bracketright"},
      {"Backslash", "backslash"}, {"Semicolon", "semicolon"},
      {"Quote", "apostrophe"}, {"Comma", "comma"}, {"Period", "period"},
      {"Slash", "slash"}, {"Backquote", "grave"},
  };
  for (const auto& e : kMap) {
    if (code == e.code) return gdk_keyval_from_name(e.name);
  }
  if (code.size() == 1) {
    return gdk_unicode_to_keyval(static_cast<guint>(code[0]));
  }
  return 0;
}

bool X11Move(int x, int y) {
#ifdef GDK_WINDOWING_X11
  Display* dpy = XDisplayOrNull();
  if (!dpy) return false;
  XTestFakeMotionEvent(dpy, -1, x, y, CurrentTime);
  XFlush(dpy);
  return true;
#else
  (void)x;
  (void)y;
  return false;
#endif
}

bool X11Button(int button, bool down) {
#ifdef GDK_WINDOWING_X11
  Display* dpy = XDisplayOrNull();
  if (!dpy) return false;
  unsigned int xbtn = 1;
  if (button == 2)
    xbtn = 3;
  else if (button == 4)
    xbtn = 2;
  XTestFakeButtonEvent(dpy, xbtn, down ? True : False, CurrentTime);
  XFlush(dpy);
  return true;
#else
  (void)button;
  (void)down;
  return false;
#endif
}

bool X11Wheel(double dx, double dy) {
#ifdef GDK_WINDOWING_X11
  Display* dpy = XDisplayOrNull();
  if (!dpy) return false;
  auto click = [&](unsigned int btn, int times) {
    for (int i = 0; i < times; ++i) {
      XTestFakeButtonEvent(dpy, btn, True, CurrentTime);
      XTestFakeButtonEvent(dpy, btn, False, CurrentTime);
    }
  };
  int v = static_cast<int>(dy / 40.0);
  if (v > 20) v = 20;
  if (v < -20) v = -20;
  if (v > 0) click(5, v);
  if (v < 0) click(4, -v);
  int h = static_cast<int>(dx / 40.0);
  if (h > 20) h = 20;
  if (h < -20) h = -20;
  if (h > 0) click(7, h);
  if (h < 0) click(6, -h);
  XFlush(dpy);
  return true;
#else
  (void)dx;
  (void)dy;
  return false;
#endif
}

bool X11Key(guint keyval, bool down) {
#ifdef GDK_WINDOWING_X11
  Display* dpy = XDisplayOrNull();
  if (!dpy || !keyval) return false;
  KeyCode kc = XKeysymToKeycode(dpy, keyval);
  if (!kc) return false;
  XTestFakeKeyEvent(dpy, kc, down ? True : False, CurrentTime);
  XFlush(dpy);
  if (down)
    g_down_keys.insert(keyval);
  else
    g_down_keys.erase(keyval);
  return true;
#else
  (void)keyval;
  (void)down;
  return false;
#endif
}

void X11ReleaseAll() {
#ifdef GDK_WINDOWING_X11
  Display* dpy = XDisplayOrNull();
  if (!dpy) return;
  for (guint keyval : g_down_keys) {
    KeyCode kc = XKeysymToKeycode(dpy, keyval);
    if (kc) XTestFakeKeyEvent(dpy, kc, False, CurrentTime);
  }
  g_down_keys.clear();
  for (unsigned int b = 1; b <= 7; ++b) {
    XTestFakeButtonEvent(dpy, b, False, CurrentTime);
  }
  XFlush(dpy);
#endif
}

std::string MakeToken(const char* prefix) {
  gchar* uuid = g_uuid_string_random();
  std::string token = std::string(prefix) + uuid;
  g_free(uuid);
  for (char& c : token) {
    if (c == '-') c = '_';
  }
  return token;
}

bool EnsurePortalProxy() {
  if (g_portal_proxy) return true;
  GError* error = nullptr;
  g_portal_proxy = g_dbus_proxy_new_for_bus_sync(
      G_BUS_TYPE_SESSION, G_DBUS_PROXY_FLAGS_NONE, nullptr,
      "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.RemoteDesktop", nullptr, &error);
  if (error) {
    g_detail = error->message;
    g_error_free(error);
    return false;
  }
  return g_portal_proxy != nullptr;
}

void OnPortalResponse(GDBusConnection* /*connection*/, const gchar* /*sender*/,
                      const gchar* /*object_path*/, const gchar* /*interface*/,
                      const gchar* /*signal*/, GVariant* parameters,
                      gpointer user_data) {
  auto* wait = static_cast<PortalWait*>(user_data);
  guint32 code = 2;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &code, &results);
  wait->done = true;
  wait->code = code;
  wait->results = results;
}

bool WaitForPortalRequest(const std::string& request_path, PortalWait* wait,
                          int timeout_iters) {
  GDBusConnection* bus = g_dbus_proxy_get_connection(g_portal_proxy);
  guint sub = g_dbus_connection_signal_subscribe(
      bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
      "Response", request_path.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      OnPortalResponse, wait, nullptr);
  for (int i = 0; i < timeout_iters && !wait->done; ++i) {
    g_main_context_iteration(nullptr, TRUE);
  }
  g_dbus_connection_signal_unsubscribe(bus, sub);
  return wait->done && wait->code == 0 && wait->results != nullptr;
}

bool PortalCall(const char* method, GVariant* params) {
  GError* error = nullptr;
  GVariant* ret = g_dbus_proxy_call_sync(g_portal_proxy, method, params,
                                         G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
                                         &error);
  if (error) {
    g_detail = error->message;
    g_error_free(error);
    return false;
  }
  if (ret) g_variant_unref(ret);
  return true;
}

bool PortalNotifyAbs(double x, double y) {
  if (!g_portal_ready || g_session_path.empty()) return false;
  GError* error = nullptr;
  GVariant* ret = g_dbus_proxy_call_sync(
      g_portal_proxy, "NotifyPointerMotionAbsolute",
      g_variant_new("(oa{sv}udd)", g_session_path.c_str(), nullptr,
                    static_cast<guint32>(0), x, y),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (error) {
    g_detail = error->message;
    g_error_free(error);
    return false;
  }
  if (ret) g_variant_unref(ret);
  return true;
}

bool PortalButton(int button, bool down) {
  if (!g_portal_ready || g_session_path.empty()) return false;
  gint32 linux_btn = 0x110;
  if (button == 2)
    linux_btn = 0x111;
  else if (button == 4)
    linux_btn = 0x112;
  return PortalCall(
      "NotifyPointerButton",
      g_variant_new("(oa{sv}iu)", g_session_path.c_str(), nullptr, linux_btn,
                    down ? 1u : 0u));
}

bool PortalAxis(double dx, double dy) {
  if (!g_portal_ready || g_session_path.empty()) return false;
  if (dy != 0) {
    if (!PortalCall("NotifyPointerAxis",
                    g_variant_new("(oa{sv}di)", g_session_path.c_str(), nullptr,
                                  dy, 0))) {
      return false;
    }
  }
  if (dx != 0) {
    if (!PortalCall("NotifyPointerAxis",
                    g_variant_new("(oa{sv}di)", g_session_path.c_str(), nullptr,
                                  dx, 1))) {
      return false;
    }
  }
  return true;
}

bool PortalKey(guint keyval, bool down) {
  if (!g_portal_ready || g_session_path.empty() || !keyval) return false;
  if (!PortalCall("NotifyKeyboardKeysym",
                  g_variant_new("(oa{sv}iu)", g_session_path.c_str(), nullptr,
                                static_cast<gint32>(keyval),
                                down ? 1u : 0u))) {
    return false;
  }
  if (down)
    g_down_keys.insert(keyval);
  else
    g_down_keys.erase(keyval);
  return true;
}

void PortalReleaseAll() {
  std::unordered_set<guint> copy = g_down_keys;
  for (guint keyval : copy) {
    PortalKey(keyval, false);
  }
  g_down_keys.clear();
  PortalButton(1, false);
  PortalButton(2, false);
  PortalButton(4, false);
}

bool StartPortalSession() {
  if (g_portal_ready) return true;
  if (!EnsurePortalProxy()) return false;

  GVariantBuilder opt;
  g_variant_builder_init(&opt, G_VARIANT_TYPE_VARDICT);
  std::string handle = MakeToken("privet_h_");
  std::string session_token = MakeToken("privet_rd_");
  g_variant_builder_add(&opt, "{sv}", "handle_token",
                        g_variant_new_string(handle.c_str()));
  g_variant_builder_add(&opt, "{sv}", "session_handle_token",
                        g_variant_new_string(session_token.c_str()));

  GError* error = nullptr;
  GVariant* ret = g_dbus_proxy_call_sync(
      g_portal_proxy, "CreateSession", g_variant_new("(a{sv})", &opt),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (error) {
    g_detail =
        std::string("RemoteDesktop CreateSession failed: ") + error->message;
    g_error_free(error);
    return false;
  }
  const char* request_path = nullptr;
  g_variant_get(ret, "(o)", &request_path);
  std::string req = request_path ? request_path : "";
  g_variant_unref(ret);

  PortalWait wait;
  if (!WaitForPortalRequest(req, &wait, 150)) {
    g_detail =
        "Wayland RemoteDesktop portal was denied or timed out. "
        "Grant remote-desktop permission when prompted.";
    if (wait.results) g_variant_unref(wait.results);
    return false;
  }

  const char* session_handle = nullptr;
  g_variant_lookup(wait.results, "session_handle", "&s", &session_handle);
  if (!session_handle) {
    g_detail = "Portal response missing session_handle.";
    g_variant_unref(wait.results);
    return false;
  }
  g_session_path = session_handle;
  g_variant_unref(wait.results);

  GVariantBuilder sel;
  g_variant_builder_init(&sel, G_VARIANT_TYPE_VARDICT);
  std::string sel_handle = MakeToken("privet_h_");
  g_variant_builder_add(&sel, "{sv}", "handle_token",
                        g_variant_new_string(sel_handle.c_str()));
  g_variant_builder_add(&sel, "{sv}", "types",
                        g_variant_new_uint32(1u | 2u));  // POINTER|KEYBOARD
  if (!PortalCall("SelectDevices", g_variant_new("(oa{sv})",
                                                 g_session_path.c_str(), &sel))) {
    return false;
  }

  GVariantBuilder start_opt;
  g_variant_builder_init(&start_opt, G_VARIANT_TYPE_VARDICT);
  std::string start_handle = MakeToken("privet_h_");
  g_variant_builder_add(&start_opt, "{sv}", "handle_token",
                        g_variant_new_string(start_handle.c_str()));
  error = nullptr;
  ret = g_dbus_proxy_call_sync(
      g_portal_proxy, "Start",
      g_variant_new("(osa{sv})", g_session_path.c_str(), "", &start_opt),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (error) {
    g_detail = error->message;
    g_error_free(error);
    return false;
  }
  const char* start_req = nullptr;
  g_variant_get(ret, "(o)", &start_req);
  std::string start_req_path = start_req ? start_req : "";
  g_variant_unref(ret);

  PortalWait start_wait;
  if (!start_req_path.empty()) {
    WaitForPortalRequest(start_req_path, &start_wait, 150);
    if (start_wait.results) g_variant_unref(start_wait.results);
    if (!start_wait.done || start_wait.code != 0) {
      g_detail = "RemoteDesktop Start was denied or timed out.";
      return false;
    }
  }

  g_portal_ready = true;
  g_detail.clear();
  return true;
}

void ProbeBackend() {
  if (IsX11Display()) {
#ifdef GDK_WINDOWING_X11
    Display* dpy = XDisplayOrNull();
    int event_base = 0, error_base = 0, major = 0, minor = 0;
    if (dpy &&
        XTestQueryExtension(dpy, &event_base, &error_base, &major, &minor)) {
      g_backend = Backend::X11;
      g_detail.clear();
      return;
    }
#endif
    g_backend = Backend::Unavailable;
    g_detail = "X11 display found but XTest is unavailable.";
    return;
  }
  if (IsWaylandDisplay()) {
    if (EnsurePortalProxy()) {
      g_backend = Backend::Portal;
      g_detail =
          "Wayland host control uses xdg-desktop-portal RemoteDesktop "
          "(permission prompt on first grant).";
      return;
    }
    g_backend = Backend::Unavailable;
    if (g_detail.empty()) {
      g_detail =
          "Wayland RemoteDesktop portal is unavailable on this compositor.";
    }
    return;
  }
  g_backend = Backend::Unavailable;
  g_detail = "Unsupported display server for remote input.";
}

FlMethodResponse* OnProbe() {
  ProbeBackend();
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(
      map, "canInject", fl_value_new_bool(g_backend != Backend::Unavailable));
  fl_value_set_string_take(map, "platform", fl_value_new_string("linux"));
  const char* backend = g_backend == Backend::X11
                            ? "XTest"
                            : (g_backend == Backend::Portal ? "xdg-desktop-portal"
                                                            : "none");
  fl_value_set_string_take(map, "backend", fl_value_new_string(backend));
  fl_value_set_string_take(map, "detail", fl_value_new_string(g_detail.c_str()));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

double ArgDouble(FlValue* args, const char* key, double fallback = 0) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v) return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v);
  return fallback;
}

int ArgInt(FlValue* args, const char* key, int fallback = 0) {
  return static_cast<int>(ArgDouble(args, key, fallback));
}

bool ArgBool(FlValue* args, const char* key, bool fallback = false) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_BOOL) return fallback;
  return fl_value_get_bool(v);
}

std::string ArgString(FlValue* args, const char* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return {};
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return {};
  return fl_value_get_string(v);
}

FlMethodResponse* OnMethod(FlMethodCall* method_call) {
  const gchar* name = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(name, "probe") == 0) {
    return OnProbe();
  }

  if (strcmp(name, "ensureReady") == 0) {
    if (g_backend == Backend::Unavailable) ProbeBackend();
    if (g_backend == Backend::Unavailable) {
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "unsupported", g_detail.c_str(), nullptr));
    }
    if (g_backend == Backend::Portal && !g_portal_ready) {
      if (!StartPortalSession()) {
        return FL_METHOD_RESPONSE(
            fl_method_error_response_new("portal", g_detail.c_str(), nullptr));
      }
    }
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (g_backend == Backend::Unavailable) ProbeBackend();
  if (g_backend == Backend::Unavailable) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("unsupported", g_detail.c_str(), nullptr));
  }

  if (g_backend == Backend::Portal && !g_portal_ready) {
    if (!StartPortalSession()) {
      return FL_METHOD_RESPONSE(
          fl_method_error_response_new("portal", g_detail.c_str(), nullptr));
    }
  }

  if (strcmp(name, "pointerMove") == 0) {
    const int w = ArgInt(args, "w", 1920);
    const int h = ArgInt(args, "h", 1080);
    const int x = ClampPixel(ArgDouble(args, "x"), w);
    const int y = ClampPixel(ArgDouble(args, "y"), h);
    bool ok =
        g_backend == Backend::X11 ? X11Move(x, y) : PortalNotifyAbs(x, y);
    if (!ok) {
      return FL_METHOD_RESPONSE(
          fl_method_error_response_new("inject", g_detail.c_str(), nullptr));
    }
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (strcmp(name, "pointerButton") == 0) {
    const int w = ArgInt(args, "w", 1920);
    const int h = ArgInt(args, "h", 1080);
    const int x = ClampPixel(ArgDouble(args, "x"), w);
    const int y = ClampPixel(ArgDouble(args, "y"), h);
    const int button = ArgInt(args, "button", 1);
    const bool down = ArgBool(args, "down", false);
    if (g_backend == Backend::X11) {
      X11Move(x, y);
      X11Button(button, down);
    } else {
      PortalNotifyAbs(x, y);
      PortalButton(button, down);
    }
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (strcmp(name, "wheel") == 0) {
    const double dx = ArgDouble(args, "dx");
    const double dy = ArgDouble(args, "dy");
    if (g_backend == Backend::X11)
      X11Wheel(dx, dy);
    else
      PortalAxis(dx, dy);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (strcmp(name, "keyEvent") == 0) {
    const std::string code = ArgString(args, "code");
    if (code == "MetaLeft" || code == "MetaRight" || code == "OSLeft" ||
        code == "OSRight" || code == "Super_L" || code == "Super_R") {
      return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
    const bool down = ArgBool(args, "down", false);
    guint keyval = KeyvalFromCode(code);
    if (g_backend == Backend::X11)
      X11Key(keyval, down);
    else
      PortalKey(keyval, down);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (strcmp(name, "releaseAll") == 0) {
    if (g_backend == Backend::X11)
      X11ReleaseAll();
    else
      PortalReleaseAll();
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
}

void MethodCallHandler(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                       gpointer /*user_data*/) {
  g_autoptr(FlMethodResponse) response = OnMethod(method_call);
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to remote_input: %s", error->message);
  }
}

}  // namespace

void remote_input_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, MethodCallHandler, nullptr,
                                            nullptr);
  static FlMethodChannel* retained =
      static_cast<FlMethodChannel*>(g_object_ref(channel));
  (void)retained;
  ProbeBackend();
}
