---
name: wechat-reply
description: Operate the local macOS WeChat auto-reply dashboard when the user asks to inspect setup, configure chat objects, manage reply modes, or review local reply feedback.
---

<!-- Managed by Loffee5422/wechat-reply-bot. -->

# WeChat Reply

Use this skill only for the user's local macOS WeChat installation and the dashboard served by this project. The tool uses macOS Accessibility through its Swift bridge and a localhost-only Python service; it does not provide official WeChat integration or guarantee risk-free automation.

## Workflow

- Check setup from the dashboard or `GET http://127.0.0.1:8765/api/setup` before changing behavior. Explain actionable hints for macOS, Swift, Codex CLI/login, Accessibility permission, or WeChat availability.
- Keep the service paused until the user selects objects and starts it. Respect include and ignore objects; group chats require an @ mention by default.
- Treat `reply_mode=model` as the default: generate a short contextual reply with the configured Codex model only when a new message needs one. The global model defaults to Luna; a contact or group can override it, while an unset override inherits the global choice. Treat `reply_mode=template` as deterministic and model-free; apply the user's template fields `{name}` and `{message}`. An available template does not override model mode.
- Preserve the default suffix `（bot回复 beta）`, avoid duplicate sends, and leave drafts or a changed chat untouched. Escalate payment, contracts, commitments, sensitive information, unknown media, or unclear instructions for user review.
- Use chat samples only to help derive a style or template. Store runtime content in the configured private data directory; never put contacts, messages, tokens, or private memory in repository files or responses.
- Feedback and manual memory edits are deterministic local operations. Describe what changed and where the user can review it; do not invent model output or claim an action was sent unless the local UI confirms it.

## Installation boundary

For a full installation, use the repository's `install.sh` and its setup checks. For only this skill, a user may install it with:

```sh
npx skills add Loffee5422/wechat-reply-bot --skill wechat-reply -a codex
```

The skill-only command does not install or start the dashboard. Do not silently grant Accessibility permission, change macOS security settings, send messages, or remove existing private skills. If the project installer finds an existing skill with differences, it backs it up under the private application data directory before installing this public copy.
