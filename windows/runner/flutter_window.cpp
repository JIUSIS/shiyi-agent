#include "flutter_window.h"

#include <optional>
#include <windows.h>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Original window procedure of the Flutter view (child window), saved when
// subclassing it so hit testing for the borderless title bar works.
WNDPROC g_original_child_proc = nullptr;

// Subclassed child-window procedure: the Flutter view covers the whole
// client area, so the top-level window never receives WM_NCHITTEST while the
// cursor is over it. Make the title-bar drag strip and the window edges
// transparent to hit testing (HTTRANSPARENT) so the system falls through to
// the top-level window, whose WM_NCHITTEST decides drag / resize / HTCLIENT.
LRESULT CALLBACK FlutterChildProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  if (message == WM_NCHITTEST) {
    POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    RECT rc;
    GetWindowRect(hwnd, &rc);
    const int x = pt.x - rc.left;
    const int y = pt.y - rc.top;
    const int w = rc.right - rc.left;
    const int h = rc.bottom - rc.top;

    HWND parent = GetParent(hwnd);
    if (parent && IsZoomed(parent) == FALSE) {
      constexpr int kEdge = 6;
      if (x < kEdge || y < kEdge || x >= w - kEdge || y >= h - kEdge) {
        return HTTRANSPARENT;
      }
    }
    // Title-bar drag strip (right of the traffic lights): fall through to the
    // top-level window (HTCAPTION drag / double-click to maximize).
    if (y >= 0 && y < kMacTitleBarHeight && x >= kMacTrafficLightsWidth) {
      return HTTRANSPARENT;
    }
  }
  return CallWindowProc(g_original_child_proc, hwnd, message, wparam, lparam);
}

}  // namespace

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Subclass the Flutter view so hit testing for the borderless title bar
  // (drag strip + resize edges) falls through to the top-level window.
  HWND child = flutter_controller_->view()->GetNativeWindow();
  if (child && !g_original_child_proc) {
    g_original_child_proc = reinterpret_cast<WNDPROC>(
        SetWindowLongPtr(child, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(FlutterChildProc)));
  }

  // macOS style window control channel: called by the Dart traffic lights.
  window_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "shiyi/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleWindowMethodCall(call, std::move(result));
      });
  last_maximized_ = IsZoomed(GetHandle()) != FALSE;

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  window_channel_ = nullptr;

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  HWND hwnd = GetHandle();
  if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
    result->Success();
  } else if (method == "toggleMaximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success();
  } else if (method == "close") {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "isMaximized") {
    result->Success(flutter::EncodableValue(IsZoomed(hwnd) != FALSE));
  } else {
    result->NotImplemented();
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Borderless window hit testing (fully custom, no system border):
  // - 6px edges: resize (HTLEFT/HTRIGHT/HTTOP/HTBOTTOM and corners)
  // - top 44px right of the traffic lights: drag region, double-click to
  //   maximize (HTCAPTION)
  // - left 96px: traffic lights (HTCLIENT, Flutter handles clicks)
  // - everything else: HTCLIENT
  // Must be handled before the Flutter engine so it is not swallowed by
  // HandleTopLevelWindowProc.
  if (message == WM_NCHITTEST) {
    POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    RECT rc;
    GetWindowRect(hwnd, &rc);
    const int x = pt.x - rc.left;
    const int y = pt.y - rc.top;
    const int w = rc.right - rc.left;
    const int h = rc.bottom - rc.top;

    if (IsZoomed(hwnd) == FALSE) {
      constexpr int kEdge = 6;
      const bool left = x < kEdge;
      const bool right = x >= w - kEdge;
      const bool top = y < kEdge;
      const bool bottom = y >= h - kEdge;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
    }
    if (y >= 0 && y < kMacTitleBarHeight && x >= kMacTrafficLightsWidth) {
      return HTCAPTION;
    }
    return HTCLIENT;
  }

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
    case WM_SIZE: {
      // Notify Dart when the maximize state changes (green button icon).
      if (window_channel_) {
        const bool maximized = (wparam == SIZE_MAXIMIZED);
        if (maximized != last_maximized_) {
          last_maximized_ = maximized;
          flutter::EncodableMap args;
          args[flutter::EncodableValue("maximized")] =
              flutter::EncodableValue(maximized);
          window_channel_->InvokeMethod(
              "windowStateChanged",
              std::make_unique<flutter::EncodableValue>(std::move(args)));
        }
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
