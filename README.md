# WeChat Reply Bot

macOS WeChat auto-reply with a local dashboard, Codex Luna, chat-derived reply styles, templates, and feedback memory. Includes a Codex skill.

[中文说明](README.zh-CN.md)

## Install

```sh
git clone https://github.com/Loffee5422/wechat-reply-bot.git && cd wechat-reply-bot && ./install.sh
```

The installer checks macOS, Python 3, Swift, the Codex CLI, and port `8765`. It does not install unknown dependencies, change macOS security settings, or grant Accessibility permission. Use `./install.sh --no-start` to generate and check the user LaunchAgent without starting it, or `./install.sh --no-open` to start the local service without opening a browser.

## Supported environment

- macOS with Python 3, Swift/Xcode Command Line Tools, and a working Codex CLI login
- macWeChat `4.1.15` dark window; the current personal-chat view classified message direction correctly for 8/8 visible messages and a selected 4-message comparison, classified personal/group headers, and sent one guarded message to File Transfer Assistant
- A local-only dashboard at `http://127.0.0.1:8765`
- Python standard library, Swift Accessibility APIs, and native HTML/CSS/JavaScript; no package dependency is required

The native kernel is still under validation, so this project does not claim every automation path is fully supported. Group chats without a clear WeChat @ marker do not trigger. History reads the currently visible sample, up to 50 messages, and reports `historyPartial=true`; it is not a complete chat-database export. Browser visual integration has not been verified. It is not an official WeChat product and cannot promise zero account or platform risk.

## Start

1. Run the installer; it starts the local dashboard and opens `http://127.0.0.1:8765` in the system default browser. Use `--no-open` when the browser should stay closed.
2. Complete the setup check and grant Accessibility access yourself if macOS asks.
3. Choose include/ignore objects, select a reply mode, then press Start. The service starts paused by default.

The LaunchAgent runs the Python local service. The Swift Accessibility helper is compiled into the private data directory when needed; grant Accessibility access to the process identified by the setup check yourself. The installer does not grant it or change macOS security settings.

If setup reports that the native screenshot preflight needs Screen Recording permission, grant it to the identified local helper. Screenshots are inspected locally for UI state and are not uploaded.

The Swift helper uses its build-time ad-hoc cdhash identity. After rebuilding or upgrading it, remove the old helper entry in macOS Privacy & Security and add the new helper again if the existing Accessibility authorization no longer applies; enabling the setting does not guarantee that an old authorization still matches.

The manual entry point is:

```sh
python3 scripts/app.py --serve --port 8765
```

Use `--data-dir <path>` when a separate private runtime directory is needed. The normal default is `~/Library/Application Support/WeChatReplyBeta`.

## Reply modes and controls

`model` is the default mode. The global model defaults to `gpt-5.6-luna` at low reasoning effort; a contact or group can override it, while an unset override inherits the global choice. A new message can invoke the selected Codex model; routine polling stays local and does not call the model. `template` is deterministic and makes no model call. Templates support `{name}` and `{message}`. The panel requires an explicit mode choice, so a saved template does not take over model mode. Only the user's current Codex account is used; there is no external provider or API configuration.

Group chats require an @ mention by default. Replies use the suffix `（bot回复 beta）`, guard against duplicate or stale sends, and leave a draft or changed chat for review. Chat samples can derive a style or template. Feedback is written deterministically to local memory, which can also be edited by hand.

## Data, quota, and privacy

Runtime state, chat-derived material, logs, memory, compiled native binaries, and skill backups stay under the private data directory and are ignored by Git. The service binds only to `127.0.0.1`. Idle polling and fixed template replies use zero model calls; a new generated reply or a manual style/template generation can call the selected model. Codex usage and limits are governed by the user's Codex account.

## Pause, uninstall, and troubleshooting

Pause from the dashboard before changing object rules or memory. To remove the user LaunchAgent and an unchanged skill installed by this project:

```sh
./uninstall.sh
```

The uninstall script keeps private memory, logs, state, and backups. If the installed skill was edited, it is preserved. For setup failures, open `/api/setup`, follow its `hint`, confirm WeChat is running and visible, and check that port `8765` is free. The installer never kills an unknown process.

## Skill-only installation

```sh
npx skills add Loffee5422/wechat-reply-bot --skill wechat-reply -a codex
```

This installs the Codex skill only; it does not replace the full installer or start the local dashboard.

## License

MIT. See [LICENSE](LICENSE).
