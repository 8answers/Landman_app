#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auth_deeplink_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.auth/deeplink",
          &flutter::StandardMethodCodec::GetInstance());
  auth_deeplink_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "consumePendingDeepLink") {
          if (pending_auth_deeplinks_.empty()) {
            result->Success(flutter::EncodableValue());
            return;
          }
          const std::string next = pending_auth_deeplinks_.front();
          pending_auth_deeplinks_.erase(pending_auth_deeplinks_.begin());
          result->Success(flutter::EncodableValue(next));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (auth_deeplink_channel_) {
    auth_deeplink_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA:
      if (HandleCopyDataMessage(lparam)) {
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

bool FlutterWindow::HandleCopyDataMessage(LPARAM lparam) noexcept {
  const auto* copy_data =
      reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (copy_data == nullptr || copy_data->lpData == nullptr ||
      copy_data->cbData <= sizeof(wchar_t)) {
    return false;
  }
  if (copy_data->dwData != 1) {
    return false;
  }

  const auto* raw_data = reinterpret_cast<const wchar_t*>(copy_data->lpData);
  const std::string uri = Utf8FromUtf16(raw_data);
  if (uri.empty()) {
    return false;
  }

  PublishDeepLinkToDart(uri);
  return true;
}

void FlutterWindow::PublishDeepLinkToDart(const std::string& uri) {
  pending_auth_deeplinks_.push_back(uri);
  if (!auth_deeplink_channel_) {
    return;
  }
  auth_deeplink_channel_->InvokeMethod(
      "onDeepLink",
      std::make_unique<flutter::EncodableValue>(uri));
}
