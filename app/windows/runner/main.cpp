#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "software_gl.h"
#include "utils.h"

namespace {

struct CreateArgs {
  FlutterWindow* window;
};

bool CreatePrivetWindow(void* param) {
  auto* args = static_cast<CreateArgs*>(param);
  return args->window->Create(L"Privet", Win32Window::Point(10, 10),
                              Win32Window::Size(1280, 720));
}

// Separate from wWinMain so __try is not in a function with C++ destructors.
int SehCreatePrivetWindow(CreateArgs* args) {
  __try {
    return CreatePrivetWindow(args) ? 1 : 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return -1;
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // A hung graphics startup keeps the single-instance port and makes the next
  // click exit immediately. Drop only windows that no longer answer.
  PrivetCloseHungWindows();

  const bool software_gl =
      PrivetCommandLineHasSoftwareGl() || PrivetNeedsSoftwareGl();
  if (software_gl) {
    // ANGLE's own "WARP" attribute list is the hardware device again, so a
    // missing or pre-11.0 GPU crashes in flutter_windows.dll. Force WARP
    // before the engine creates its display. Dart reads the variable to turn
    // on the cheap animation path.
    SetEnvironmentVariableW(L"PRIVET_SOFTWARE_GL", L"1");
    PrivetInstallSoftwareGlHook();
  }

  flutter::DartProject project(L"data");

  // Flutter 3.35+ merges the Windows UI + platform threads by default. That
  // starves vsync / Dart timers so caret blink, typing dots, and Kolobok
  // stickers freeze on the first frame while Linux/Android keep moving.
  // Opt back out until the engine run-loop regressions are gone.
  // https://github.com/flutter/flutter/issues/175135
  project.set_ui_thread_policy(
      flutter::UIThreadPolicy::RunOnSeparateThread);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  if (software_gl) {
    bool already = false;
    for (const auto& arg : command_line_arguments) {
      if (arg == "--privet-software-gl") {
        already = true;
        break;
      }
    }
    if (!already) {
      command_line_arguments.push_back("--privet-software-gl");
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // A fault here is the no-GPU crash. Relaunch once on WARP instead of
  // unwinding a dead heap.
  CreateArgs create_args{&window};
  const int created = SehCreatePrivetWindow(&create_args);
  if (created != 1) {
    if (!software_gl) {
      PrivetRelaunchSoftwareGl();
    }
    if (created < 0) {
      ::MessageBoxW(nullptr,
                    L"Privet could not start graphics on this PC.",
                    L"Privet", MB_OK | MB_ICONERROR);
    }
    return EXIT_FAILURE;
  }
  // Quit-on-close stays true for a real destroy. Dart `window_manager`
  // intercepts WM_CLOSE when preventClose is set (close → hide to tray);
  // Profile / tray "Quit Privet" clears preventClose and destroys.
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
