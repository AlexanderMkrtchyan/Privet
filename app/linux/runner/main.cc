#include "my_application.h"

int main(int argc, char** argv) {
  // GtkFileChooserNative otherwise hops through xdg-desktop-portal-gnome
  // (GTK4), which takes ~10s to list folders like Downloads with 1000+ files.
  g_setenv("GTK_USE_PORTAL", "0", TRUE);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
