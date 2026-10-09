#include "my_application.h"

int main(int argc, char** argv) {
  // GtkFileChooserNative otherwise hops through xdg-desktop-portal-gnome
  // (GTK4), which takes ~10s to list folders like Downloads with 1000+ files.
  g_setenv("GTK_USE_PORTAL", "0", TRUE);
  // GDK consumes XDG_ACTIVATION_TOKEN during startup. Keep a copy so a second
  // launch can hand GNOME 50's token to the already-running window.
  const gchar* activation = g_getenv("XDG_ACTIVATION_TOKEN");
  if (activation == nullptr || activation[0] == '\0') {
    activation = g_getenv("DESKTOP_STARTUP_ID");
  }
  if (activation != nullptr && activation[0] != '\0') {
    g_setenv("PRIVET_ACTIVATION_TOKEN", activation, TRUE);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
