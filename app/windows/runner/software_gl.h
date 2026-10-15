#ifndef RUNNER_SOFTWARE_GL_H_
#define RUNNER_SOFTWARE_GL_H_

// True when this PC has no Direct3D 11.0 hardware adapter. Flutter's ANGLE
// path then faults inside flutter_windows.dll instead of falling back, which
// is the startup crash on old Windows PCs and machines whose only display
// device is Microsoft Basic Display Adapter.
bool PrivetNeedsSoftwareGl();

// True when this process was started with --privet-software-gl.
bool PrivetCommandLineHasSoftwareGl();

// Make ANGLE's D3D11 display use the WARP software device. Call before the
// Flutter window is created. No-op when the import cannot be patched.
void PrivetInstallSoftwareGlHook();

// End a previous Privet whose window no longer answers. A responsive window
// (including one hidden to the tray) is left alone so the single-instance
// handoff can raise it.
void PrivetCloseHungWindows();

// Start a new process with --privet-software-gl and exit this one. Used after
// the graphics device faults, when the heap may already be unsafe.
void PrivetRelaunchSoftwareGl();

#endif  // RUNNER_SOFTWARE_GL_H_
