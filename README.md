# 拾忆 ShiYi

> 运行在 Android 手机上的个人 AI 工作台

📦 **下载安装**：[shiyi-agent-v1.0.0.apk](https://github.com/JIUSIS/shiyi-agent/releases/download/v1.0.0/shiyi-agent-v1.0.0.apk) · [GitHub Releases](https://github.com/JIUSIS/shiyi-agent/releases)

拾忆（ShiYi）是一款运行在 Android 手机上的个人 AI 工作台。

它将大语言模型、长期记忆、项目文件管理、内置终端和技能系统整合到一个移动应用中，让 AI 不只是回答问题，还可以参与实际工作：读取资料、修改文件、运行命令、整理项目。

## 功能特性

- 支持接入不同 LLM API 与模型切换
- 多轮对话与独立会话管理（搜索 / 重命名 / 删除 / 左滑操作）
- 每个会话可设置独立项目工作目录
- 文件附件多选，图片多选与拍照，支持视觉模型图片理解
- 内置无需 root 的终端环境（bash / python3 / apt 装包）
- 长期记忆：保存用户偏好、项目背景与工作记录
- 技能系统：输入 `/` 快速选择技能，按固定流程处理任务
- 网页搜索与网页内容提取、多来源交叉验证
- 语音朗读、浅色 / 深色 / 跟随系统主题
- 内置终端访问手机存储，权限由系统授权管理

## 核心设计

### 独立项目目录

每个会话都可以设置单独的项目工作目录。AI 在当前会话中创建、读取和修改的文件默认围绕该目录管理，不同会话对应不同项目，互不干扰。

### 内置终端

应用内集成了移动端终端环境（bash + python3），不需要额外安装 Termux，也不需要 root。可用于查看处理文件、运行 Python 脚本、执行文本处理命令、在项目目录中运行工具。

### 技能系统

支持加载不同技能，让 AI 按照指定流程完成小说审计、资料整理、代码分析、内容创作等任务。

## 技术栈

- Flutter / Dart
- Android（targetSdk 34）
- SQLite（会话与消息存储）
- 内置 Termux 用户空间环境（bootstrap 固化进 assets）
- LLM API + 多模态图片处理

## 构建

```bash
# 安装依赖
flutter pub get

# 运行（debug）
flutter run

# 构建 release APK
# 需在 android/local.properties 或环境变量中提供 KEYSTORE_PASSWORD（签名密码，不入库）
flutter build apk --release
```

签名凭据（`keystore.jks`）与本地构建配置（`android/local.properties`）均被 `.gitignore` 排除，不随源码提交。

## 使用说明

1. 安装应用并完成初始配置
2. 在设置中填写 LLM API 信息并选择模型
3. 新建会话，必要时为会话设置项目目录
4. 开始对话；需要处理文件或运行命令时，直接让 AI 在当前项目目录中完成操作

## 隐私与数据

会话、设置、长期记忆和项目数据默认保存在设备本地。发送给模型的内容取决于用户配置的 API 服务与实际对话内容。请在使用第三方 LLM API 时了解对应服务商的隐私政策。

## 许可证

本项目基于 [GPL-3.0](LICENSE) 开源发布。使用、修改与分发请遵守 GPL-3.0 协议条款。
