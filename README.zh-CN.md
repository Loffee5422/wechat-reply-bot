# WeChat Reply Bot

面向 macOS 微信的本地自动回复工具：本地控制面板、Codex Luna、从聊天样本提取回复风格、模板和反馈记忆，并附带 Codex skill。

[English README](README.md)

## 安装

```sh
git clone https://github.com/Loffee5422/wechat-reply-bot.git && cd wechat-reply-bot && ./install.sh
```

安装器检查 macOS、Python 3、Swift、Codex CLI 和 `8765` 端口；不会自动安装来源不明的依赖、修改系统安全设置或偷偷授予辅助功能权限。正常安装会启动本地服务并打开系统默认浏览器；使用 `--no-open` 可启动服务但不打开浏览器。先只检查并生成用户 LaunchAgent：

```sh
./install.sh --no-start
```

## 支持环境

- macOS、Python 3、Swift/Xcode Command Line Tools，以及已登录的 Codex CLI
- macWeChat `4.1.15` 深色窗口；已验证当前个人聊天可见消息方向 8/8、指定 4 条对照 4/4、个人/群聊 header 分类，以及向“文件传输助手”受保护的单条发送
- 仅监听 `http://127.0.0.1:8765` 的本地面板
- 只使用 Python 标准库、Swift 辅助功能 API 和原生 HTML/CSS/JavaScript，无第三方包依赖

原生内核仍在验证中，因此不宣称所有自动化路径都已完整支持。没有明确微信 @ 标记的群聊不会触发。历史读取当前可见样本，最多 50 条，并返回 `historyPartial=true`；这不是完整聊天数据库导出。浏览器视觉联调尚未验证。项目不是微信官方产品，也不承诺零风控风险。

## 三步启动

1. 运行安装器并打开面板。
2. 完成 setup 检查；如果 macOS 提示，请由用户自行授予辅助功能权限。
3. 选择包含/忽略对象，选择回复模式后按 Start。服务默认 paused。

LaunchAgent 运行 Python 本地服务；需要时由它在私有 data-dir 编译并运行 Swift 辅助功能 helper。请根据 setup 检查显示的进程在系统设置中自行授予辅助功能权限，安装器不会代为授权或修改安全设置。

如果 setup 报告原生截图预检需要“屏幕录制”权限，请仅向它标出的本地 helper 授权。截图只在本机用于识别界面状态，不会上传。

Swift helper 使用编译时生成的 ad-hoc cdhash 身份。重新编译或升级后，如果原有辅助功能授权不再适用，请在 macOS“隐私与安全性”中删除旧 helper 条目，再添加新的 helper 并重新授权；开关处于开启状态不保证旧授权仍然匹配。

手动启动入口：

```sh
python3 scripts/app.py --serve --port 8765
```

需要独立私有目录时加 `--data-dir <path>`；默认目录是 `~/Library/Application Support/WeChatReplyBeta`。

## 模式与边界

`model` 是默认模式。全局模型默认是 `gpt-5.6-luna` 低推理强度；联系人或群可以单独设置 override，未设置时继承全局选择。只有新消息确实需要生成回复时才调用所选 Codex 模型，平时 10 秒本地检测不调用模型。`template` 是固定模板模式，零模型调用，支持 `{name}` 和 `{message}`。面板要求明确二选一，非空模板不会自动抢占 model 模式。只使用当前 Codex 账号，不增加外部 provider 或 API 配置。

群聊默认只有被 @ 才回复。回复默认带 `（bot回复 beta）`，并防止重复发送、聊天切换或草稿被覆盖。聊天本人样本可用于提取风格或模板；反馈会确定性写入本地 memory，也可以手工编辑。支付、合同、承诺、敏感隐私、未知媒体或不清晰指令交给用户确认。

## 数据、额度与隐私

运行时状态、聊天派生内容、日志、memory、原生编译缓存和 skill 备份保存在私有数据目录，并由 Git 忽略。空闲检测和固定模板回复不调用模型；新消息生成回复、手动生成风格或模板时可能调用所选模型。实际额度以用户 Codex 账户为准。个人内容不会随仓库发布。

## 暂停、卸载与排错

修改规则或 memory 前先在面板暂停。卸载本工具的 LaunchAgent 和本次安装且未被修改的 skill：

```sh
./uninstall.sh
```

卸载会保留私有 memory、日志、状态和备份；如果 skill 被用户编辑，会保留它。安装失败时查看 `GET /api/setup` 的可读 `hint`，确认微信正在运行、窗口可见且 `8765` 空闲。安装器不会杀掉未知进程。

## 只安装 Codex skill

```sh
npx skills add Loffee5422/wechat-reply-bot --skill wechat-reply -a codex
```

此命令只安装 skill，不代替完整安装，也不会启动本地面板。

## 许可证

MIT，见 [LICENSE](LICENSE)。
