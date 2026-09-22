#!/bin/bash
set -euo pipefail

USER_HOME=${HOME:?HOME is not set}
DATA_DIR=${WECHAT_REPLY_DATA_DIR:-"$USER_HOME/Library/Application Support/WeChatReplyBeta"}
SKILL_DIR="$USER_HOME/.codex/skills/wechat-reply"
PLIST="$USER_HOME/Library/LaunchAgents/com.lofe.wechat-reply-beta.plist"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

manifest="$SKILL_DIR/skill-install-manifest"
if [[ -f "$manifest" && -f "$SKILL_DIR/SKILL.md" ]]; then
  expected=$(sed -n '1p' "$manifest")
  actual=$(shasum -a 256 "$SKILL_DIR/SKILL.md" | awk '{print $1}')
  if [[ "$expected" == "$actual" ]]; then
    extras=$(find "$SKILL_DIR" -type f ! -name SKILL.md ! -name skill-install-manifest ! -path "$SKILL_DIR/agents/openai.yaml" -print -quit)
    if [[ -z "$extras" ]]; then rm -rf "$SKILL_DIR"; else printf 'Preserved modified skill directory: %s\n' "$SKILL_DIR"; fi
  else
    printf 'Preserved modified skill: %s\n' "$SKILL_DIR"
  fi
fi

printf "%s\n" "Removed this tool's LaunchAgent and unchanged installed skill."
printf 'Kept user data at %s (memory, logs, state, and backups).\n' "$DATA_DIR"
