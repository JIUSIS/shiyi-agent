#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// macOS style borderless window title bar constants (keep in sync with the
// Dart side MacTitleBar): the top 44px is the drag region (press-move to
// drag, double-click to maximize; do not report HTCAPTION or Win11 paints
// a gray caption overlay). The left 96px is reserved for the traffic lights.
constexpr int kMacTitleBarHeight = 44;
constexpr int kMacTrafficLightsWidth = 96;

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Native title-bar overlay (covers Win11 DWM caption hover).
  HWND GetTitleBarHandle() const { return title_bar_hwnd_; }

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

  void SetTitleBarColor(COLORREF color);
  void RaiseTitleBarOverlay();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  void CreateTitleBarOverlay();
  void DestroyTitleBarOverlay();
  void LayoutTitleBarOverlay();
  static LRESULT CALLBACK TitleBarProc(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam);
  void PaintTitleBar(HWND hwnd);
  void HitTitleBar(HWND hwnd, int x, int y, int* button_out) const;
  int TitleBarHeightPx() const;
  int TrafficLightsWidthPx() const;

  bool quit_on_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // Native overlay that sits above DWM's caption hover layer.
  HWND title_bar_hwnd_ = nullptr;

  // Hovered traffic-light index: 0 close, 1 min, 2 max, -1 none.
  int title_bar_hover_ = -1;

  // Matches Flutter MacTitleBar (light scaffold). Dart may update this.
  COLORREF title_bar_color_ = RGB(0xF2, 0xF2, 0xF7);

  // window handle for hosted content.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
