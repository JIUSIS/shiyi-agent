# ShiYi Agent App（拾忆）项目说明

## 部署偏好（用户明确要求）
- 安装到真机时**必须使用覆盖安装**（如 `adb install -r` 或签名一致的 `flutter install`），**禁止先卸载再安装**。
- 卸载会清掉 app 数据（API Key / 模型 / 会话 / 记忆），用户每次都要重新配置，体验很差。
- 日常开发用 debug 签名构建（`flutter install --debug` 或 `adb install -r build\app\outputs\flutter-apk\app-debug.apk`），签名一致时覆盖安装不会清数据。
- **⚠️ 2026-08-08 实测教训：`flutter install --debug` 不可靠**——其内部先跑 `adb install -t -r`，失败时会**自动卸载重装**（日志出现 `Uninstalling old version...`），app 数据被清空。已两次踩坑。
  - **首选安装方式：手动 `adb install -r`**（同一 debug keystore 下实测 Success，数据保留）。
  - 用 `flutter install` 时：装完必须检查输出里**没有** `Uninstalling old version...`，有则说明走了卸载（数据已清）。
  - 装前可先验签：`adb shell dumpsys package com.shiyi.agent | grep signatures`（同签名覆盖才不清数据）。
  - 备份数据（debug 包可 run-as）：`adb exec-out run-as com.shiyi.agent cat files/... `（app_flutter/shiyi_agent.db + shared_prefs/）。

## 真机环境
- 常用测试设备：`2509FPN0BC`（Android 16 / API 36）
- 应用包名：`com.shiyi.agent`（由 `com.hermes.hermes_agent_app` 改名而来）