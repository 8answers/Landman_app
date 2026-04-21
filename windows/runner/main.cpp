#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cctype>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {
constexpr wchar_t kAppWindowTitle[] = L"8answers";
constexpr wchar_t kFlutterWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kSingleInstanceMutexName[] = L"Local\\8answers_singleton";

bool IsAuthDeepLink(const std::string& value) {
  const std::string trimmed = value;
  if (trimmed.empty()) {
    return false;
  }
  const std::string lower = [&trimmed]() {
    std::string output = trimmed;
    for (char& c : output) {
      c = static_cast<char>(::tolower(static_cast<unsigned char>(c)));
    }
    return output;
  }();
  return lower.rfind("com.example.landmanwebsite://", 0) == 0 ||
         lower.rfind("8answers://", 0) == 0;
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return L"";
  }
  const int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(), -1, nullptr, 0);
  if (target_length <= 0) {
    return L"";
  }
  std::wstring utf16_string(static_cast<size_t>(target_length - 1), L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(), -1, utf16_string.data(),
      target_length);
  if (converted <= 0) {
    return L"";
  }
  return utf16_string;
}

std::wstring ExtractAuthDeepLinkArg(const std::vector<std::string>& args) {
  for (const auto& arg : args) {
    if (!IsAuthDeepLink(arg)) {
      continue;
    }
    const std::wstring as_utf16 = Utf16FromUtf8(arg);
    if (!as_utf16.empty()) {
      return as_utf16;
    }
  }
  return L"";
}

HWND FindPrimaryWindowHandle() {
  HWND window = ::FindWindow(kFlutterWindowClassName, nullptr);
  if (window != nullptr) {
    return window;
  }
  return ::FindWindow(nullptr, kAppWindowTitle);
}

void BringWindowToForeground(HWND hwnd) {
  if (hwnd == nullptr) {
    return;
  }
  ::ShowWindow(hwnd, SW_RESTORE);
  ::SetForegroundWindow(hwnd);
}

void ForwardDeepLinkToPrimaryWindow(HWND hwnd, const std::wstring& deep_link) {
  if (hwnd == nullptr || deep_link.empty()) {
    return;
  }
  COPYDATASTRUCT copy_data{};
  copy_data.dwData = 1;
  copy_data.cbData =
      static_cast<DWORD>((deep_link.size() + 1) * sizeof(wchar_t));
  copy_data.lpData = const_cast<wchar_t*>(deep_link.c_str());
  ::SendMessage(hwnd, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&copy_data));
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const std::wstring auth_deep_link =
      ExtractAuthDeepLinkArg(command_line_arguments);

  HANDLE app_mutex =
      ::CreateMutex(nullptr, TRUE, kSingleInstanceMutexName);
  const bool already_running = (app_mutex != nullptr &&
                                ::GetLastError() == ERROR_ALREADY_EXISTS);
  if (already_running) {
    HWND primary_window = FindPrimaryWindowHandle();
    if (!auth_deep_link.empty() && primary_window == nullptr) {
      // A callback can arrive while the first instance is still starting up.
      // Retry briefly so we don't drop the auth deep-link.
      for (int attempt = 0; attempt < 20 && primary_window == nullptr;
           ++attempt) {
        ::Sleep(100);
        primary_window = FindPrimaryWindowHandle();
      }
    }

    if (primary_window != nullptr) {
      if (!auth_deep_link.empty()) {
        ForwardDeepLinkToPrimaryWindow(primary_window, auth_deep_link);
      }
      BringWindowToForeground(primary_window);
      if (app_mutex != nullptr) {
        ::CloseHandle(app_mutex);
      }
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }

    // If no primary window can be resolved, continue startup in this process
    // so the auth callback arguments still reach Dart instead of being lost.
  }

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"8answers", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (app_mutex != nullptr) {
    ::ReleaseMutex(app_mutex);
    ::CloseHandle(app_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
