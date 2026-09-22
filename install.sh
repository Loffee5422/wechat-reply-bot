#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
USER_HOME=${HOME:?HOME is not set}
DATA_DIR=${WECHAT_REPLY_DATA_DIR:-"$USER_HOME/Library/Application Support/WeChatReplyBeta"}
SKILL_DIR="$USER_HOME/.codex/skills/wechat-reply"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS/com.lofe.wechat-reply-beta.plist"
PORT=${WECHAT_REPLY_PORT:-8765}
NO_START=0
NO_OPEN=0

usage() { printf 'Usage: %s [--no-start] [--no-open]\n' "$(basename "$0")"; }
for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    --no-open) NO_OPEN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done
fail() { printf 'install: %s\n' "$1" >&2; exit 1; }

[[ $(uname -s) == Darwin ]] || fail 'macOS is required.'
PYTHON=$(command -v python3 || true)
[[ -n "$PYTHON" ]] || fail 'Python 3 is required. Install it from python.org or Homebrew, then rerun install.sh.'
SWIFTC=/usr/bin/swiftc
[[ -x "$SWIFTC" ]] || fail 'Swift compiler not found at /usr/bin/swiftc. Install Xcode Command Line Tools, then rerun install.sh.'

CODEX=$(command -v codex || true)
if [[ -z "$CODEX" ]]; then
  for candidate in "$USER_HOME/Applications/Codex.app/Contents/Resources/codex" "/Applications/Codex.app/Contents/Resources/codex" "$USER_HOME/Applications/Codex.app/Contents/MacOS/codex" "/Applications/Codex.app/Contents/MacOS/codex"; do
    if [[ -x "$candidate" ]]; then CODEX=$candidate; break; fi
  done
fi
[[ -n "$CODEX" ]] || fail 'Codex CLI was not found. Open the Codex app or install its CLI, then rerun install.sh.'
"$CODEX" --version >/dev/null 2>&1 || fail 'Codex CLI was found but could not run. Check the Codex installation, then rerun install.sh.'
CODEX_DIR=$(CDPATH= cd -- "$(dirname -- "$CODEX")" && pwd)
[[ -f "$PROJECT_DIR/scripts/app.py" ]] || fail 'scripts/app.py is missing from this checkout.'
[[ -f "$PROJECT_DIR/skills/wechat-reply/SKILL.md" ]] || fail 'The public wechat-reply skill is missing.'

if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "TCP port $PORT is already in use; stop that service or set WECHAT_REPLY_PORT to a free port."
fi

mkdir -p "$DATA_DIR" "$DATA_DIR/bin" "$DATA_DIR/state" "$DATA_DIR/run" "$DATA_DIR/logs" "$DATA_DIR/memory" "$LAUNCH_AGENTS"
chmod 700 "$DATA_DIR" "$DATA_DIR/state" "$DATA_DIR/memory" "$DATA_DIR/logs"

if [[ -d "$SKILL_DIR" ]]; then
  if ! diff -qr --exclude='skill-install-manifest' "$PROJECT_DIR/skills/wechat-reply" "$SKILL_DIR" >/dev/null 2>&1; then
    backup="$DATA_DIR/skill-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup"
    cp -R "$SKILL_DIR/." "$backup/"
    printf 'Existing skill backed up to %s\n' "$backup"
  fi
  rm -rf "$SKILL_DIR"
fi
mkdir -p "$SKILL_DIR"
cp -R "$PROJECT_DIR/skills/wechat-reply/." "$SKILL_DIR/"
printf '%s\n' "$(shasum -a 256 "$SKILL_DIR/SKILL.md" | awk '{print $1}')" > "$SKILL_DIR/skill-install-manifest"
chmod 600 "$SKILL_DIR/skill-install-manifest"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.lofe.wechat-reply-beta</string>
  <key>ProgramArguments</key>
  <array><string>$PYTHON</string><string>$PROJECT_DIR/scripts/app.py</string><string>--serve</string><string>--port</string><string>$PORT</string><string>--data-dir</string><string>$DATA_DIR</string></array>
  <key>WorkingDirectory</key><string>$PROJECT_DIR</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$CODEX_DIR:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DATA_DIR/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/logs/launchd.err.log</string>
</dict>
</plist>
EOF
chmod 600 "$PLIST"

if [[ "$NO_START" -eq 1 ]]; then
  printf 'Install checks passed. LaunchAgent generated at %s; service not started.\n' "$PLIST"
  exit 0
fi
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
if [[ "$NO_OPEN" -eq 0 ]]; then
  open "http://127.0.0.1:$PORT"
  printf 'Installed and started the local dashboard at http://127.0.0.1:%s\n' "$PORT"
else
  printf 'Installed and started the local dashboard at http://127.0.0.1:%s (browser not opened).\n' "$PORT"
fi
