# 拾忆（ShiYi）Windows 桌面版构建快速指南

> 本文档只写构建步骤；**Windows 端完整维护手册（架构/适配/排错/验证/铁律）见
> `docs/windows-maintenance.md`**。手机端文档见 `AGENTS.md` 与 `docs/fix-log.md`。

## 构建

```powershell
flutter create --platforms=windows .   # 仅首次：生成 windows/ 平台目录
flutter pub get
flutter build windows --release
```

前置条件：Flutter stable（3.44.x）+ Visual Studio（Windows 桌面 C++ 工具链）。

## 产物

`build\windows\x64\runner\Release\shiyi_agent.exe`

⚠️ **分发必须整体拷贝 Release 目录**（exe + `flutter_windows.dll` + 各插件 DLL +
`sqlite3.dll` + `data/`），单拷 exe 会因缺 DLL 无法启动。

## 常见构建报错速查

| 报错 | 原因 | 处理 |
|---|---|---|
| C4819 | C++ 注释含中文（GBK 代码页） | 注释改英文（`windows/runner/` 保持纯 ASCII） |
| C4996 | `getenv`/`fopen` 不安全 API | 用 `_dupenv_s`/`fopen_s` |
| C2338 / STL1011 | permission_handler_windows 的 `<experimental/coroutine>` 与新 MSVC 冲突 | `windows/CMakeLists.txt` 已加抑制宏，勿删 |
| 缺 `KEYSTORE_PASSWORD` | 这是 Android debug 构建的签名要求，与 Windows 构建无关 | Windows 构建不需要 keystore |

更多排错与维护要点见 `docs/windows-maintenance.md` 第 5~7 节。
