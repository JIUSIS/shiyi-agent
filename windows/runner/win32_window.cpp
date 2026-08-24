#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_COLOR_NONE
#define DWMWA_COLOR_NONE 0xFFFFFFFE
#endif
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef WM_NCUAHDRAWCAPTION
#define WM_NCUAHDRAWCAPTION 0x00AE
#endif
#ifndef WM_NCUAHDRAWFRAME
#define WM_NCUAHDRAWFRAME 0x00AF
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// WS_EX_DROPSHADOW may be missing when _WIN32_WINNT is not defined.
#ifndef WS_EX_DROPSHADOW
#define WS_EX_DROPSHADOW 0x00020000L
#endif

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // Layered + popup: Win11 DWM does not paint the caption hover overlay
  // on WS_EX_LAYERED windows. Keep THICKFRAME / MINIMIZEBOX / MAXIMIZEBOX
  // for snap. The Flutter MacTitleBar is the only title chrome.
  HWND window = CreateWindowEx(
      WS_EX_DROPSHADOW | WS_EX_APPWINDOW, window_class, title.c_str(),
      WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
          WS_CLIPCHILDREN,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (window) {
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  }

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      DestroyTitleBarOverlay();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      LayoutTitleBarOverlay();
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      UpdateTheme(hwnd);
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_NCUAHDRAWCAPTION:
    case WM_NCUAHDRAWFRAME:
      return 0;

    case WM_GETTITLEBARINFOEX: {
      auto* info = reinterpret_cast<TITLEBARINFOEX*>(lparam);
      if (info && info->cbSize >= sizeof(TITLEBARINFOEX)) {
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
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();
  DestroyTitleBarOverlay();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  if (!title_bar_hwnd_) {
    CreateTitleBarOverlay();
  }
  LayoutTitleBarOverlay();
  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  CreateTitleBarOverlay();
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
  MARGINS margins = {0, 0, 0, 0};
  DwmExtendFrameIntoClientArea(window, &margins);
  if (Win32Window* that = GetThisFromHandle(window)) {
    if (that->title_bar_hwnd_) {
      InvalidateRect(that->title_bar_hwnd_, nullptr, TRUE);
    }
  }
}

int Win32Window::TitleBarHeightPx() const {
  const UINT dpi = GetDpiForWindow(window_handle_);
  return MulDiv(kMacTitleBarHeight, dpi, 96);
}

int Win32Window::TrafficLightsWidthPx() const {
  const UINT dpi = GetDpiForWindow(window_handle_);
  return MulDiv(kMacTrafficLightsWidth, dpi, 96);
}

void Win32Window::CreateTitleBarOverlay() {
  if (!window_handle_ || title_bar_hwnd_) {
    return;
  }
  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASS wc{};
    wc.style = CS_DBLCLKS;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = L"SHIYI_TITLEBAR";
    wc.hInstance = GetModuleHandle(nullptr);
    wc.lpfnWndProc = TitleBarProc;
    wc.hbrBackground = nullptr;
    RegisterClass(&wc);
    class_registered = true;
  }
  title_bar_hwnd_ = CreateWindowEx(
      0, L"SHIYI_TITLEBAR", L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0,
      0, 0, window_handle_, nullptr, GetModuleHandle(nullptr), this);
  LayoutTitleBarOverlay();
}

void Win32Window::DestroyTitleBarOverlay() {
  if (title_bar_hwnd_) {
    DestroyWindow(title_bar_hwnd_);
    title_bar_hwnd_ = nullptr;
  }
}

void Win32Window::RaiseTitleBarOverlay() {
  LayoutTitleBarOverlay();
}

void Win32Window::SetTitleBarColor(COLORREF color) {
  title_bar_color_ = color;
  if (title_bar_hwnd_) {
    InvalidateRect(title_bar_hwnd_, nullptr, TRUE);
  }
}

void Win32Window::LayoutTitleBarOverlay() {
  if (!window_handle_ || !title_bar_hwnd_) {
    return;
  }
  RECT rc = GetClientArea();
  const int height = TitleBarHeightPx();
  SetWindowPos(title_bar_hwnd_, HWND_TOP, rc.left, rc.top,
               rc.right - rc.left, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOCOPYBITS);
}

void Win32Window::HitTitleBar(HWND hwnd, int x, int y, int* button_out) const {
  *button_out = -1;
  const UINT dpi = GetDpiForWindow(window_handle_ ? window_handle_ : hwnd);
  const int pad = MulDiv(14, dpi, 96);
  const int size = MulDiv(12, dpi, 96);
  const int gap = MulDiv(8, dpi, 96);
  const int bar_h = MulDiv(kMacTitleBarHeight, dpi, 96);
  const int cy = bar_h / 2;
  const int hit = MulDiv(10, dpi, 96);
  for (int i = 0; i < 3; ++i) {
    const int cx = pad + size / 2 + i * (size + gap);
    if (abs(x - cx) <= hit && abs(y - cy) <= hit) {
      *button_out = i;
      return;
    }
  }
}

void Win32Window::PaintTitleBar(HWND hwnd) {
  PAINTSTRUCT ps;
  HDC hdc = BeginPaint(hwnd, &ps);
  RECT rc;
  GetClientRect(hwnd, &rc);

  HBRUSH bg_brush = CreateSolidBrush(title_bar_color_);
  FillRect(hdc, &rc, bg_brush);
  DeleteObject(bg_brush);

  const UINT dpi = GetDpiForWindow(window_handle_ ? window_handle_ : hwnd);
  const int pad = MulDiv(14, dpi, 96);
  const int size = MulDiv(12, dpi, 96);
  const int gap = MulDiv(8, dpi, 96);
  const int bar_h = rc.bottom - rc.top;
  const int top = (bar_h - size) / 2;
  const COLORREF colors[3] = {RGB(0xFF, 0x5F, 0x57), RGB(0xFE, 0xBC, 0x2E),
                              RGB(0x28, 0xC8, 0x40)};

  for (int i = 0; i < 3; ++i) {
    const int left = pad + i * (size + gap);
    HBRUSH brush = CreateSolidBrush(colors[i]);
    HPEN pen = CreatePen(PS_SOLID, 1, colors[i]);
    HGDIOBJ old_b = SelectObject(hdc, brush);
    HGDIOBJ old_p = SelectObject(hdc, pen);
    Ellipse(hdc, left, top, left + size, top + size);
    if (title_bar_hover_ == i) {
      HPEN icon_pen = CreatePen(PS_SOLID, 1, RGB(0x40, 0x40, 0x40));
      SelectObject(hdc, icon_pen);
      const int m = MulDiv(3, dpi, 96);
      const int cx = left + size / 2;
      const int cy = top + size / 2;
      if (i == 0) {
        MoveToEx(hdc, left + m, top + m, nullptr);
        LineTo(hdc, left + size - m, top + size - m);
        MoveToEx(hdc, left + size - m, top + m, nullptr);
        LineTo(hdc, left + m, top + size - m);
      } else if (i == 1) {
        MoveToEx(hdc, left + m, cy, nullptr);
        LineTo(hdc, left + size - m, cy);
      } else {
        const bool maximized = IsZoomed(window_handle_);
        if (maximized) {
          MoveToEx(hdc, cx - m, cy, nullptr);
          LineTo(hdc, cx, cy + m);
          LineTo(hdc, cx + m, cy);
        } else {
          MoveToEx(hdc, cx - m, cy, nullptr);
          LineTo(hdc, cx, cy - m);
          LineTo(hdc, cx + m, cy);
        }
      }
      SelectObject(hdc, old_p);
      DeleteObject(icon_pen);
    }
    SelectObject(hdc, old_b);
    SelectObject(hdc, old_p);
    DeleteObject(brush);
    DeleteObject(pen);
  }
  EndPaint(hwnd, &ps);
}

LRESULT CALLBACK Win32Window::TitleBarProc(HWND window, UINT message,
                                           WPARAM wparam, LPARAM lparam) {
  Win32Window* that = nullptr;
  if (message == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    that = static_cast<Win32Window*>(cs->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(that));
  } else {
    that = reinterpret_cast<Win32Window*>(
        GetWindowLongPtr(window, GWLP_USERDATA));
  }
  if (!that) {
    return DefWindowProc(window, message, wparam, lparam);
  }

  switch (message) {
    case WM_PAINT:
      that->PaintTitleBar(window);
      return 0;
    case WM_ERASEBKGND:
      return 1;
    case WM_MOUSEMOVE: {
      TRACKMOUSEEVENT tme{};
      tme.cbSize = sizeof(tme);
      tme.dwFlags = TME_LEAVE;
      tme.hwndTrack = window;
      TrackMouseEvent(&tme);
      int button = -1;
      that->HitTitleBar(window, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam),
                        &button);
      if (button != that->title_bar_hover_) {
        that->title_bar_hover_ = button;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      if (that->title_bar_hover_ != -1) {
        that->title_bar_hover_ = -1;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    case WM_LBUTTONDOWN: {
      int button = -1;
      that->HitTitleBar(window, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam),
                        &button);
      if (button < 0 && that->window_handle_) {
        ReleaseCapture();
        SendMessage(that->window_handle_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      int button = -1;
      that->HitTitleBar(window, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam),
                        &button);
      if (button == 0 && that->window_handle_) {
        PostMessage(that->window_handle_, WM_CLOSE, 0, 0);
      } else if (button == 1 && that->window_handle_) {
        ShowWindow(that->window_handle_, SW_MINIMIZE);
      } else if (button == 2 && that->window_handle_) {
        ShowWindow(that->window_handle_,
                   IsZoomed(that->window_handle_) ? SW_RESTORE : SW_MAXIMIZE);
      }
      return 0;
    }
    case WM_LBUTTONDBLCLK: {
      int button = -1;
      that->HitTitleBar(window, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam),
                        &button);
      if (button < 0 && that->window_handle_) {
        ShowWindow(that->window_handle_,
                   IsZoomed(that->window_handle_) ? SW_RESTORE : SW_MAXIMIZE);
      }
      return 0;
    }
    default:
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}
