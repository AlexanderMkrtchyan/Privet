#include <glib.h>

// GLib 2.80's gtype.h routes the type-registration fast path through
// g_once_init_enter_pointer / g_once_init_leave_pointer (G_DEFINE_TYPE),
// so every translation unit compiled against glib >= 2.80 headers emits an
// (unversioned) reference to these two functions. Ubuntu 22.04 ships glib
// 2.72, which only exports the classic gsize-based g_once_init_enter /
// g_once_init_leave; the bundle then dies at load with
//   symbol lookup error: undefined symbol: g_once_init_enter_pointer
//
// The pointer variants are ABI-identical to the classic ones (glib's own
// implementation casts the location to gsize* and calls the same internals),
// so define them here, forwarding to the long-existing API. The executable is
// linked with -Wl,--export-dynamic (see CMakeLists.txt), so the definitions
// land in the global symbol scope and satisfy the plugin libraries' references
// at load time on both new and old glib.
extern "C" {

// The gthread.h macros would re-wrap the calls; call the plain functions.
#undef g_once_init_enter
#undef g_once_init_leave
#undef g_once_init_enter_pointer
#undef g_once_init_leave_pointer

gboolean g_once_init_enter_pointer(void* location) {
  return g_once_init_enter((volatile void*)location);
}

void g_once_init_leave_pointer(void* location, gpointer result) {
  g_once_init_leave((volatile void*)location, (gsize)result);
}

}  // extern "C"
