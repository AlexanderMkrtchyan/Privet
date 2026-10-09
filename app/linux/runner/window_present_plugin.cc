#include "window_present_plugin.h"

#include <gdk/gdk.h>
#include <gtk/gtk.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include <cstring>

namespace {

constexpr const char* kChannelName = "privet/window";

FlPluginRegistrar* g_registrar = nullptr;

GtkWindow* GetWindow() {
  if (g_registrar == nullptr) return nullptr;
  FlView* view = fl_plugin_registrar_get_view(g_registrar);
  if (view == nullptr) return nullptr;
  GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (!GTK_IS_WINDOW(top)) return nullptr;
  return GTK_WINDOW(top);
}

void ApplyActivationToken(const char* token) {
  if (token == nullptr || token[0] == '\0') return;
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) return;
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(display)) {
    gdk_x11_display_set_startup_notification_id(display, token);
    return;
  }
#endif
#ifdef GDK_WINDOWING_WAYLAND
  if (GDK_IS_WAYLAND_DISPLAY(display)) {
    gdk_wayland_display_set_startup_notification_id(display, token);
  }
#endif
}

gboolean DropKeepAbove(gpointer data) {
  GtkWindow* window = GTK_WINDOW(data);
  if (GTK_IS_WINDOW(window)) {
    gtk_window_set_keep_above(window, FALSE);
  }
  g_object_unref(window);
  return G_SOURCE_REMOVE;
}

void PresentWindow(GtkWindow* window, const char* token) {
  ApplyActivationToken(token);
  // GNOME 50 / Mutter ignores gtk_window_present from a tray or notification
  // click unless the xdg-activation token from that click is applied first.
  // keep-above still maps a hidden XWayland surface when the token is missing
  // (tray menu). Drop it on the next turn so the window is not pinned.
  gtk_window_deiconify(window);
  gtk_window_set_keep_above(window, TRUE);
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_present(window);
  g_timeout_add(200, DropKeepAbove, g_object_ref(G_OBJECT(window)));
}

FlMethodResponse* OnPresent(FlValue* args) {
  GtkWindow* window = GetWindow();
  if (window == nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(false);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  const char* token = nullptr;
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* value = fl_value_lookup_string(args, "token");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      token = fl_value_get_string(value);
    }
  }
  PresentWindow(window, token);
  g_autoptr(FlValue) result = fl_value_new_bool(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

void MethodCallHandler(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                       gpointer /*user_data*/) {
  const gchar* name = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(name, "present") == 0) {
    response = OnPresent(fl_method_call_get_args(method_call));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to privet/window: %s", error->message);
  }
}

}  // namespace

void window_present_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  g_registrar = registrar;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, MethodCallHandler, nullptr,
                                            nullptr);
  static FlMethodChannel* retained =
      static_cast<FlMethodChannel*>(g_object_ref(channel));
  (void)retained;
}
