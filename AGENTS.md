# ShiYi Agent App（拾忆）项目说明

## 部署偏好（用户明确要求）
- 安装到真机时**必须使用覆盖安装**（如 `adb install -r` 或签名一致的 `flutter install`），**禁止先卸载再安装**。
- 卸载会清掉 app 数据（API Key / 模型 / 会话 / 记忆），用户每次都要重新配置，体验很差。
- 日常开发用 debug 签名构建（`flutter install --debug` 或 `adb install -r build\app\outputs\flutter-apk\app-debug.apk`），签名一致时覆盖安装不会清数据。

## 真机环境
- 常用测试设备：`2509FPN0BC`（Android 16 / API 36）
- 应用包名：`com.shiyi.agent`（由 `com.hermes.hermes_agent_app` 改名而来）