#include "flutter_window.h"

#include <commctrl.h>
#include <cstdint>
#include <optional>
#include <windows.h>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

#ifndef WM_NCUAHDRAWCAPTION
#define WM_NCUAHDRAWCAPTION 0x00AE
#endif
#ifndef WM_NCUAHDRAWFRAME
#define WM_NCUAHDRAWFRAME 0x00AF
#endif

namespace {

constexpr UINT_PTR kFlutterChildSubclassId = 1;

// Flutter's view is a WS_CHILD covering the client area, so the top-level
// window never sees WM_NCHITTEST over it. Edges and the title-bar drag
// strip return HTTRANSPARENT so the parent can drag / resize. Traffic
// lights stay HTCLIENT so Dart receives the clicks.
LRESULT CALLBACK FlutterChildSubclass(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam, UINT_PTR /*subclass_id*/,
                                      DWORD_PTR /*ref_data*/) {
  if (message == WM_NCHITTEST) {
    POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    RECT rc;
    GetWindowRect(hwnd, &rc);
    const int x = pt.x - rc.left;
    const int y = pt.y - rc.top;
    const int w = rc.right - rc.left;
    const int h = rc.bottom - rc.top;

    UINT dpi = 96;
    HWND parent = GetParent(hwnd);
    if (parent) {
      dpi = GetDpiForWindow(parent);
    }
    const int title_h = MulDiv(kMacTitleBarHeight, dpi, 96);
    const int lights_w = MulDiv(kMacTrafficLightsWidth, dpi, 96);
    const bool in_title = y >= 0 && y < title_h;

    if (parent && IsZoomed(parent) == FALSE) {
      constexpr int kEdge = 6;
      if (!in_title && (x < kEdge || x >= w - kEdge || y >= h - kEdge)) {
        return HTTRANSPARENT;
      }
    }
    if (in_title && x < lights_w) {
      return HTCLIENT;
    }
    if (in_title && x >= lights_w) {
      return HTTRANSPARENT;
    }
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

void HookFlutterChild(HWND child) {
  if (!child) {
    return;
  }
  RemoveWindowSubclass(child, FlutterChildSubclass, kFlutterChildSubclassId);
  SetWindowSubclass(child, FlutterChildSubclass, kFlutterChildSubclassId, 0);
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

  // Pin hit testing on the Flutter view. Re-hook after the first frame in
  // case the engine replaces the child WndProc during startup.
  HWND child = flutter_controller_->view()->GetNativeWindow();
  HookFlutterChild(child);

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
    if (this->flutter_controller_ && this->flutter_controller_->view()) {
      HookFlutterChild(this->flutter_controller_->view()->GetNativeWindow());
    }
    this->RaiseTitleBarOverlay();
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
  } else if (method == "setTitleBarColor") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("color"));
      if (it != args->end()) {
        int64_t argb = 0;
        if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
          argb = static_cast<uint32_t>(*v32);
        } else if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
          argb = *v64;
        }
        if (argb != 0) {
          SetTitleBarColor(RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF,
                               argb & 0xFF));
        }
      }
    }
    result->Success();
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
  // - top 44px right of the traffic lights: HTCLIENT (drag handled below)
  // - left 96px: traffic lights (HTCLIENT, Flutter handles clicks)
  // - everything else: HTCLIENT
  // Do not return HTCAPTION: Win11 draws a gray caption overlay on hover.
  // Must be handled before the Flutter engine so it is not swallowed by
  // HandleTopLevelWindowProc.
  if (message == WM_NCCALCSIZE && wparam == TRUE) {
    auto* sz = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    if (IsZoomed(hwnd)) {
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      MONITORINFO mi{};
      mi.cbSize = sizeof(mi);
      if (GetMonitorInfo(monitor, &mi)) {
        sz->rgrc[0] = mi.rcWork;
      }
    }
    return 0;
  }
  if (message == WM_GETTITLEBARINFOEX) {
    auto* info = reinterpret_cast<TITLEBARINFOEX*>(lparam);
    if (info && info->cbSize >= sizeof(TITLEBARINFOEX)) {
      // Win11 paints the gray caption overlay over rcTitleBar. An empty
      // rect is what actually disables it; hiding buttons alone is not
      // enough, and DefWindowProc pre-fills this before we see it.
      SetRectEmpty(&info->rcTitleBar);
      ZeroMemory(info->rgstate, sizeof(info->rgstate));
      ZeroMemory(info->rgrect, sizeof(info->rgrect));
      for (int i = 0; i <= CCHILDREN_TITLEBAR; ++i) {
        info->rgstate[i] = STATE_SYSTEM_INVISIBLE | STATE_SYSTEM_UNAVAILABLE |
                           STATE_SYSTEM_OFFSCREEN;
        SetRectEmpty(&info->rgrect[i]);
      }
    }
    return 0;
  }
  if (message == WM_NCACTIVATE) {
    // -1 tells DefWindowProc not to repaint the non-client caption.
    return DefWindowProc(hwnd, message, wparam, static_cast<LPARAM>(-1));
  }
  if (message == WM_NCPAINT || message == WM_NCUAHDRAWCAPTION ||
      message == WM_NCUAHDRAWFRAME) {
    return 0;
  }
  if (message == WM_NCHITTEST) {
    POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    RECT rc;
    GetWindowRect(hwnd, &rc);
    const int x = pt.x - rc.left;
    const int y = pt.y - rc.top;
    const int w = rc.right - rc.left;
    const int h = rc.bottom - rc.top;
    const UINT dpi = GetDpiForWindow(hwnd);
    const int title_h = MulDiv(kMacTitleBarHeight, dpi, 96);
    const bool in_title = y >= 0 && y < title_h;

    if (IsZoomed(hwnd) == FALSE) {
      constexpr int kEdge = 6;
      const bool left = x < kEdge;
      const bool right = x >= w - kEdge;
      const bool top = !in_title && y < kEdge;
      const bool bottom = y >= h - kEdge;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left && !in_title) return HTLEFT;
      if (right && !in_title) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
    }
    return HTCLIENT;
  }

  auto in_title_drag_strip = [hwnd](LPARAM lp) -> bool {
    const int x = GET_X_LPARAM(lp);
    const int y = GET_Y_LPARAM(lp);
    const UINT dpi = GetDpiForWindow(hwnd);
    const int title_h = MulDiv(kMacTitleBarHeight, dpi, 96);
    const int lights_w = MulDiv(kMacTrafficLightsWidth, dpi, 96);
    return y >= 0 && y < title_h && x >= lights_w;
  };

  if (message == WM_LBUTTONDOWN && in_title_drag_strip(lparam)) {
    title_bar_tracking_ = true;
    title_bar_press_ = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    SetCapture(hwnd);
    return 0;
  }
  if (message == WM_MOUSEMOVE && title_bar_tracking_ &&
      (wparam & MK_LBUTTON)) {
    const int x = GET_X_LPARAM(lparam);
    const int y = GET_Y_LPARAM(lparam);
    const int dx = abs(x - title_bar_press_.x);
    const int dy = abs(y - title_bar_press_.y);
    if (dx > GetSystemMetrics(SM_CXDRAG) || dy > GetSystemMetrics(SM_CYDRAG)) {
      title_bar_tracking_ = false;
      ReleaseCapture();
      POINT cursor{};
      GetCursorPos(&cursor);
      SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION,
                  MAKELPARAM(cursor.x, cursor.y));
    }
    return 0;
  }
  if (message == WM_LBUTTONUP && title_bar_tracking_) {
    title_bar_tracking_ = false;
    ReleaseCapture();
    return 0;
  }
  if (message == WM_CAPTURECHANGED) {
    title_bar_tracking_ = false;
  }
  if (message == WM_LBUTTONDBLCLK && in_title_drag_strip(lparam)) {
    title_bar_tracking_ = false;
    ReleaseCapture();
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    return 0;
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
