#include "flutter_window.h"

#include <memory>
#include <optional>
#include <vector>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "kotv_iface_rx.h"

// 子窗口专用原生通道：销毁当前子窗口。
// 必须绕过 WM_CLOSE——flutter_windows 引擎收到 WM_CLOSE 会走全局 RunLoop 的
// PostQuitMessage，把主窗口连同整个进程一起退出。这里用 DestroyWindow 直接
// 销毁子窗口根窗口（不经 WM_CLOSE），主窗口与进程保持存活。
static std::vector<std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_playback_window_channels;

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
  // 独立播放窗口：每个子窗口注册全部插件（media_kit / window_manager 等），
  // 并注册「destroySelf」原生通道，供子窗口 Dart 侧安全关闭自身。
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);

    auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        flutter_view_controller->engine()->messenger(), "kotv_playback_native",
        &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler(
        [flutter_view_controller](const flutter::MethodCall<flutter::EncodableValue> &call,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
          HWND hwnd = flutter_view_controller->view()->GetNativeWindow();
          HWND root = hwnd ? ::GetAncestor(hwnd, GA_ROOT) : nullptr;
          if (call.method_name() == "destroySelf") {
            if (root) {
              // 绕过 WM_CLOSE 直接销毁子窗口，避免 Flutter 全局 RunLoop
              // PostQuitMessage 把主窗口一起退出。
              ::DestroyWindow(root);
            }
            result->Success(flutter::EncodableValue(true));
          } else if (call.method_name() == "moveToDefault") {
            // 把子窗口放到屏幕右侧中部，避免叠在主窗口中央遮挡主界面。
            if (root) {
              RECT rc;
              ::GetWindowRect(root, &rc);
              int w = rc.right - rc.left;
              int h = rc.bottom - rc.top;
              int sw = ::GetSystemMetrics(SM_CXSCREEN);
              int sh = ::GetSystemMetrics(SM_CYSCREEN);
              int x = sw - w - 60;
              int y = (sh - h) / 2;
              if (x < 0) x = 0;
              if (y < 0) y = 0;
              ::SetWindowPos(root, nullptr, x, y, 0, 0,
                             SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            }
            result->Success(flutter::EncodableValue(true));
          } else {
            result->NotImplemented();
          }
        });
    g_playback_window_channels.push_back(std::move(channel));
  });
  RegisterHostChannel();
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

void FlutterWindow::RegisterHostChannel() {
  host_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "kotv_host",
      &flutter::StandardMethodCodec::GetInstance());
  host_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getInterfaceRxBytes") {
          result->Success(flutter::EncodableValue(KotvInterfaceRxBytes()));
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::OnDestroy() {
  host_channel_ = nullptr;
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
