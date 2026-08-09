# 拾忆 ShiYi

> 运行在 Android 手机上的个人 AI 工作台 —— 让 AI 不只是回答问题，而是参与你的实际工作：读取资料、修改文件、运行命令、整理项目。

[![Release](https://img.shields.io/github/v/release/JIUSIS/shiyi-agent)](https://github.com/JIUSIS/shiyi-agent/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-important)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android-3DDC84)](https://github.com/JIUSIS/shiyi-agent/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B)](https://flutter.dev)

📦 **下载安装**：[shiyi-agent-v1.1.0.apk](https://github.com/JIUSIS/shiyi-agent/releases/download/v1.1.0/shiyi-agent-v1.1.0.apk) · [GitHub Releases](https://github.com/JIUSIS/shiyi-agent/releases)

---

## 关于拾忆

拾忆（ShiYi）是一款运行在 Android 手机上的个人 AI 工作台。它将大语言模型、长期记忆、项目文件管理、内置终端与技能系统整合为一个应用，让 AI 从"聊天助手"升级为"随身工作伙伴"——你可以把资料丢给它、把项目交给它、把重复任务委托给它，它会在你的手机里完成实际工作。

## 功能特性

### 智能对话

- 接入不同 LLM API，随时切换模型
- 多轮对话与独立会话管理（搜索 / 重命名 / 删除 / 左滑快捷操作）
- 每个会话可设置独立项目工作目录，多项目互不干扰
- 文件 / 图片多选附件，支持视觉模型图片理解
- 流式输出、自动重试、上下文自动压缩
- 思考过程流式展示，长思考自动滚动跟随

### 子代理（委派分工）

- `spawn_agent`：让 AI 派出专项子代理分头处理子任务，干完交回报告
- 内置四类：`explore` 只读侦查、`plan` 只读方案设计、`worker` 独立执行、`general-purpose` 兜底
- **并行派发**：一次 `tasks` 数组派多个子代理（最多 4 个）同时跑，互不阻塞、单个失败不影响其他，界面显示「子代理 i/N」进度
- **动态轮数预算**：每任务可用 `max_turns`（1~80）按复杂度动态调整（简单 5~10、复杂 40~60），省时省钱
- **写路径隔离**：并行 `worker` 可各自声明 `write_paths`，越界写入会被执行层拒绝，互不覆盖文件
- 子代理执行进度实时可见（当前轮次 / 正在调用的工具）
- 安全设计：工具白名单、禁止递归委派、轮次上限

### 内置终端

- 集成移动端终端环境（bash / python3 / apt），**无需安装 Termux、无需 root**
- 软件包管理器内置国内镜像与自动切换（清华 / 南大 / 北大 / 中科大等）
- 支持运行 Python 脚本、文本处理、项目管理工具

### 记忆与技能

- 长期记忆：自动记住你的偏好、项目背景与工作记录
- 技能系统：输入 `/` 快速选择技能，按固定流程完成资料整理、代码分析、内容创作、小说审计等任务——任何可流程化的工作都能固化成技能
- 网页搜索与网页内容提取、多来源交叉验证

### 更多能力

- 语音朗读、浅色 / 深色 / 跟随系统主题
- 项目文件可视化浏览
- 内置日志与排障能力

## 界面预览

| 主页 | 侧边栏 | 记忆 |
| --- | --- | --- |
| ![主页](docs/screenshots/home.jpg) | ![侧边栏](docs/screenshots/sidebar.jpg) | ![记忆](docs/screenshots/memory.jpg) |

| 技能 | 文件 | 设置 | 关于 |
| --- | --- | --- | --- |
| ![技能](docs/screenshots/skills.jpg) | ![文件](docs/screenshots/files.jpg) | ![设置](docs/screenshots/settings.jpg) | ![关于](docs/screenshots/about.jpg) |

## 安装

1. 从 [Releases](https://github.com/JIUSIS/shiyi-agent/releases) 下载 APK（Android 8.0+）
2. 安装后打开应用，完成初始配置
3. 首次启动会自动部署内置终端环境（约 40MB），请耐心等待

> 提示：更新版本请直接覆盖安装（`adb install -r` 或允许系统覆盖），不会清除本地数据。

## 快速开始

1. 打开 **设置**，填写 LLM API 信息（Base URL / API Key）并选择模型
2. 返回首页，点击 **新建会话**
3. 如有需要，在会话中设置项目工作目录
4. 开始对话；需要处理文件或运行命令时，直接让 AI 在当前项目目录中完成操作

## 核心设计

### 独立项目目录

每个会话都可以设置单独的项目工作目录。AI 在当前会话中创建、读取和修改的文件默认围绕该目录管理，不同会话对应不同项目，互不干扰。

### 内置终端（免 root）

应用内集成了移动端终端环境（bash + python3），不需要额外安装 Termux，也不需要 root。它基于 Android 应用沙箱 + 内嵌用户空间（proot）实现，首次启动自动部署，开箱即用。

### 技能系统

支持加载不同技能，让 AI 按照指定流程完成资料整理、代码分析、内容创作、报告生成、小说写作与审计等任务——不只是写小说，任何可流程化、可复用的工作都能固化成技能。技能即流程，一次配置，反复复用。

## 技术栈

| 层次 | 技术 |
| --- | --- |
| 客户端 | Flutter / Dart（Android，targetSdk 27，兼容 SELinux 直接执行内嵌终端 ELF） |
| 数据存储 | SQLite（会话与消息）、SharedPreferences（设置） |
| 终端环境 | 内置 Termux 用户空间（bootstrap 固化进 assets，proot 沙箱） |
| 模型接入 | LLM API + 多模态图片处理 |

## 从源码构建

```bash
# 安装依赖
flutter pub get

# 运行（debug）
flutter run

# 构建 release APK（需先配置签名，见下）
flutter build apk --release
```

### Release 签名配置

`android/app/build.gradle.kts` 的 release 签名配置读取项目根目录的 `keystore.jks`（keyAlias 为 `shiyi`），签名密码从 `android/local.properties` 的 `KEYSTORE_PASSWORD` 或环境变量 `KEYSTORE_PASSWORD` 读取。

首次构建 release 需要：

```bash
# 1. 生成签名密钥（只需一次；请务必妥善保管密码）
keytool -genkeypair -v -keystore keystore.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias shiyi -dname "CN=ShiYi, OU=ShiYi, O=ShiYi, L=Beijing, ST=Beijing, C=CN"

# 2. 配置密码（二选一）
#    方式 A：写入 android/local.properties（不入库）
echo "KEYSTORE_PASSWORD=你的密码" >> android/local.properties
#    方式 B：构建时用环境变量
export KEYSTORE_PASSWORD="你的密码"
flutter build apk --release
```

> 注意：`keystore.jks` 与 `android/local.properties` 均被 `.gitignore` 排除，**不随源码提交**。丢失密钥意味着无法再对已发布的版本做覆盖更新（签名不一致），请务必备份。


## 隐私与数据

- 会话、设置、长期记忆和项目数据**默认保存在设备本地**，不上传任何服务器
- 发送给模型的内容取决于你配置的 API 服务与实际对话内容
- 使用第三方 LLM API 时，请了解对应服务商的隐私政策

## 开源许可证

本项目基于 [GPL-3.0](LICENSE) 协议开源。使用、修改与分发请遵守 GPL-3.0 条款。

---

**拾忆 ShiYi** · 让每一次对话，都留下成果。
