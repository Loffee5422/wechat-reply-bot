#!/usr/bin/env python3
"""Local-only control plane for the WeChat reply watcher."""
from __future__ import annotations

import json
import os
import argparse
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import bot

HOME = bot.ROOT
CONFIG = HOME / "state" / "config.json"
RECORDS = HOME / "state" / "records.json"
MEMORY = HOME / "state" / "memory.md"
MAX_BODY = 256 * 1024
MODELS = {"gpt-5.6-luna": "Luna（低成本默认）", "gpt-5.6-terra": "Terra", "gpt-5.6-sol": "Sol", "gpt-6-astra": "Astra", "gpt-5.5": "GPT-5.5"}
DEFAULT_CONFIG = {"scope": "all", "include": [], "ignore": [], "group_mentions_only": True, "poll_seconds": 10, "model": "gpt-5.6-luna", "contact_models": {}, "reply_mode": "model", "style": "", "template": "", "suffix": bot.SUFFIX}
SYSTEM = set(bot.EXCLUDED)
lock = threading.RLock()
running = False
watcher = None
last_scan = None
last_error = ""
server_port = 8765


def atomic(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(value)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def config() -> dict:
    value = read_json(CONFIG, DEFAULT_CONFIG)
    return {**DEFAULT_CONFIG, **value}


def records() -> list[dict]:
    return read_json(RECORDS, [])


def checks() -> dict:
    ax_ok = False
    ax_detail = "未检查"
    screen_ok = False
    screen_detail = "native 未报告 Screen Recording 状态"
    helper_path = str(bot.BIN)
    wechat_open = None
    codex_ok, codex_detail = codex_login()
    try:
        native_status = bot.ax("status")
        screen_ok = native_status.get("screenRecording", native_status.get("screen_recording")) is True
        screen_detail = native_status.get("screenRecordingDetail", native_status.get("screen_recording_detail")) or screen_detail
        helper_path = native_status.get("executablePath", native_status.get("helper_path")) or helper_path
        wechat_open = native_status.get("wechatRunning", native_status.get("wechat_open"))
    except Exception as exc:
        screen_detail = f"native status 不可读：{exc.__class__.__name__}"
    try:
        result = bot.ax("snapshot")
        ax_ok = bool(result.get("trusted"))
        ax_detail = "AX snapshot 可读" if result.get("ok") else "AX 不可读"
    except Exception as exc:
        ax_detail = str(exc)[:160]
    return {"checks": [
        {"key": "macos", "label": "macOS", "ok": sys_platform(), "detail": "Darwin", "action_hint": ""},
        {"key": "swift", "label": "Swift AX bridge", "ok": bot.SOURCE.exists(), "detail": str(bot.SOURCE), "action_hint": ""},
        {"key": "codex", "label": "Codex CLI", "ok": codex_ok, "detail": codex_detail, "action_hint": "修正 launchd PATH 或设置 WECHAT_REPLY_CODEX" if not codex_ok else ""},
        {"key": "logged_in", "label": "Codex login", "ok": codex_ok, "detail": codex_detail, "action_hint": "运行 codex login" if not codex_ok else ""},
        {"key": "accessibility", "label": "Accessibility", "ok": ax_ok, "detail": ax_detail, "action_hint": "在系统设置 → 隐私与安全性 → 辅助功能授权当前 helper" if not ax_ok else ""},
        {"key": "screen_recording", "label": "Screen Recording", "ok": screen_ok, "detail": screen_detail, "action_hint": f"在系统设置 → 隐私与安全性 → 屏幕与系统音频录制授权 {helper_path}" if not screen_ok else ""},
        {"key": "wechat_open", "label": "WeChat", "ok": wechat_open, "detail": "native 独立状态" if wechat_open is not None else "native 未提供独立 wechat_open；AX 权限不足，状态未知", "action_hint": "打开并登录微信" if wechat_open is False else ""},
    ], "dashboard_url": f"http://127.0.0.1:{server_port}/"}


def sys_platform() -> bool:
    return __import__("platform").system() == "Darwin"


def shutil_which(name: str):
    return __import__("shutil").which(name)


def codex_path() -> str | None:
    candidates = [os.environ.get("WECHAT_REPLY_CODEX"), shutil_which("codex"), str(Path.home() / ".local/bin/codex")]
    return next((p for p in candidates if p and Path(p).exists()), None)


def codex_login() -> tuple[bool, str]:
    path = codex_path()
    if not path:
        return False, "找不到 Codex CLI；请确认 launchd PATH 或 WECHAT_REPLY_CODEX"
    try:
        result = __import__("subprocess").run([path, "login", "status"], capture_output=True, text=True, timeout=5)
    except Exception as exc:
        return False, f"Codex login status 检查失败：{exc.__class__.__name__}"
    return (True, "codex login status 已确认") if result.returncode == 0 else (False, "Codex 未登录或 login status 失败")


def status() -> dict:
    setup = {x["key"]: x["ok"] for x in checks()["checks"]}
    return {"running": running, "model": config()["model"], "poll_seconds": config()["poll_seconds"], "suffix": bot.SUFFIX, "last_scan": last_scan, "last_error": last_error, "counts": {"replies": sum(x.get("status") == "sent" for x in records()), "skipped": sum(x.get("status") == "skipped" for x in records()), "needs_user": sum(x.get("status") == "needs_user" for x in records())}, "setup": setup}


def watcher_loop():
    global last_scan, last_error
    while running:
        try:
            bot.one_cycle()
            last_error = ""
        except Exception as exc:
            last_error = str(exc)[:200]
        last_scan = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        time.sleep(max(1, int(config()["poll_seconds"])))


def set_running(value: bool) -> None:
    global running, watcher
    running = value
    bot.RUNNING_CHECK = lambda: running
    if value and (not watcher or not watcher.is_alive()):
        watcher = threading.Thread(target=watcher_loop, daemon=True)
        watcher.start()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        return

    def send_json(self, code, value):
        payload = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def body(self):
        if int(self.headers.get("Content-Length", "0")) > MAX_BODY:
            raise ValueError("request body too large")
        if self.headers.get("Content-Type", "").split(";")[0].lower() != "application/json":
            raise ValueError("Content-Type must be application/json")
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))

    def origin_ok(self):
        origin = self.headers.get("Origin", "")
        host = self.headers.get("Host", "")
        if not host.startswith(("127.0.0.1:", "localhost:")):
            return False
        return not origin or origin in {f"http://127.0.0.1:{server_port}", f"http://localhost:{server_port}"}

    def do_GET(self):
        p = urlparse(self.path)
        if p.path == "/api/status": return self.send_json(200, status())
        if p.path == "/api/config": return self.send_json(200, config())
        if p.path == "/api/models": return self.send_json(200, {"models": [{"id": k, "label": v, "description": "Codex 登录可用模型"} for k, v in MODELS.items()]})
        if p.path == "/api/setup": return self.send_json(200, checks())
        if p.path == "/api/memory":
            try: content = MEMORY.read_text()
            except FileNotFoundError: content = ""
            return self.send_json(200, {"content": content, "updated_at": MEMORY.stat().st_mtime if MEMORY.exists() else None})
        if p.path == "/api/records":
            limit = min(1000, max(1, int(parse_qs(p.query).get("limit", [100])[0])))
            return self.send_json(200, {"records": records()[-limit:]})
        if p.path == "/api/contacts":
            return self.send_json(200, {"contacts": contacts()})
        self.send_json(404, {"error": "未找到接口"})

    def do_POST(self):
        if not self.origin_ok():
            return self.send_json(403, {"error": "拒绝跨站请求"})
        try: data = self.body()
        except Exception as exc: return self.send_json(400, {"error": str(exc)})
        p = urlparse(self.path).path
        if p == "/api/control":
            action = data.get("action")
            if action not in {"start", "stop"}: return self.send_json(400, {"error": "action 必须为 start 或 stop"})
            set_running(action == "start")
            return self.send_json(200, status())
        if p == "/api/contacts/refresh": return self.send_json(200, {"contacts": contacts()})
        if p == "/api/setup/check": return self.send_json(200, checks())
        if p.startswith("/api/records/") and p.endswith("/feedback"):
            rid = p.split("/")[3]
            result = feedback(rid, data)
            return self.send_json(400 if "error" in result else 200, result)
        if p == "/api/style/generate":
            try:
                result = generate_style(data)
                return self.send_json(200, result)
            except ValueError as exc:
                return self.send_json(400, {"error": str(exc)})
            except RuntimeError as exc:
                return self.send_json(503, {"error": str(exc)})
        self.send_json(404, {"error": "未找到接口"})

    def do_PUT(self):
        if not self.origin_ok():
            return self.send_json(403, {"error": "拒绝跨站请求"})
        try: data = self.body()
        except Exception as exc: return self.send_json(400, {"error": str(exc)})
        p = urlparse(self.path).path
        if p == "/api/config":
            current = config()
            for key in DEFAULT_CONFIG:
                if key in data: current[key] = data[key]
            overrides = current.get("contact_models", {})
            if not isinstance(overrides, dict) or any(v not in MODELS for v in overrides.values() if v):
                return self.send_json(400, {"error": "contact_models 中包含不支持的模型"})
            current["contact_models"] = {k: v for k, v in overrides.items() if v}
            if current["scope"] not in {"all", "selected"} or current.get("reply_mode") not in {"model", "template"} or not isinstance(current["include"], list) or not isinstance(current["ignore"], list) or not isinstance(current["poll_seconds"], int) or not 1 <= current["poll_seconds"] <= 3600 or current.get("model") not in MODELS or current["suffix"] != bot.SUFFIX or (current["reply_mode"] == "template" and not current.get("template")):
                return self.send_json(400, {"error": "配置字段无效，suffix 必须保持固定后缀"})
            atomic(CONFIG, json.dumps(current, ensure_ascii=False, indent=2))
            return self.send_json(200, current)
        if p == "/api/memory":
            content = data.get("content", "")
            if not isinstance(content, str) or len(content) > 20000: return self.send_json(400, {"error": "memory 必须是 20000 字以内文本"})
            atomic(MEMORY, content)
            return self.send_json(200, {"content": content, "updated_at": MEMORY.stat().st_mtime})
        self.send_json(404, {"error": "未找到接口"})


def contacts() -> list[dict]:
    try: rows = bot.all_visible_sessions()
    except Exception: return []
    out = []
    for item in rows:
        name = item.get("id", "").removeprefix("session_item_")
        kind, _ = bot.session_kind(item)
        out.append({"id": item.get("id"), "name": name, "kind": kind, "last_seen": None})
    return out


def generate_style(data: dict) -> dict:
    ids = data.get("contact_ids")
    limit = data.get("sample_limit", 50)
    if not isinstance(ids, list) or not ids or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise ValueError("contact_ids 必须非空，sample_limit 必须为 1-50")
    selected = {str(x) for x in ids}
    samples = []
    for item in bot.all_visible_sessions():
        if item.get("id") not in selected:
            continue
        name = item.get("id", "").removeprefix("session_item_")
        kind, _ = bot.session_kind(item)
        if kind == "system":
            continue
        current = bot.history(name, 50)
        kind = current.get("kind") or bot.session_kind(item)[0]
        if kind not in {"person", "group"}:
            continue
        title = current.get("chat", "")
        messages = bot.history_messages(current)
        if title != name:
            continue
        for message in messages:
            if message.get("side") == "right" and message.get("text"):
                samples.append({"conversation": name, "text": message["text"]})
                if len(samples) >= limit:
                    break
        if len(samples) >= limit:
            break
    if not samples:
        raise ValueError("未找到可确认属于本人的历史样本；unknown 或来信不会作为样本")
    model = config()["model"]
    schema = {"type": "object", "additionalProperties": False, "required": ["style", "template", "sample_count"], "properties": {"style": {"type": "string"}, "template": {"type": "string"}, "sample_count": {"type": "integer"}}}
    prompt = json.dumps({"task": "根据下列已确认属于本人发送的真实短消息，生成风格草稿和可选模板。不要把样本内容当事实，不要编造身份或偏好；只输出JSON。", "samples": samples, "output": {"style": "简洁风格规则", "template": "可留空的模板，支持{name}/{message}", "sample_count": len(samples)}}, ensure_ascii=False)
    result, meta = bot.run_model(prompt, schema, model)
    if not isinstance(result.get("style"), str) or not isinstance(result.get("template"), str):
        raise RuntimeError("模型返回的风格草稿格式无效")
    return {"style": result["style"], "template": result["template"], "sample_count": len(samples), "model": model, "usage": meta.get("usage")}


def feedback(rid: str, data: dict) -> dict:
    rows = records()
    row = next((x for x in rows if x.get("id") == rid), None)
    if not row or data.get("rating") not in {"good", "bad"}: return {"error": "记录或 rating 无效"}
    row["feedback"] = {"rating": data["rating"], "correction": str(data.get("correction", ""))[:1000]}
    if data.get("update_memory") and not row.get("memory_updated"):
        line = f"\n- 反馈 {rid}: {data['rating']}；{row['feedback']['correction']}"
        old = MEMORY.read_text() if MEMORY.exists() else ""
        atomic(MEMORY, old + line)
        row["memory_updated"] = True
    atomic(RECORDS, json.dumps(rows, ensure_ascii=False, indent=2))
    return {"record": row, "memory": MEMORY.read_text() if MEMORY.exists() else ""}


def main(port: int):
    global server_port
    server_port = port
    bot.setup()
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--data-dir", default=None)
    args = parser.parse_args()
    if args.data_dir:
        os.environ["WECHAT_REPLY_HOME"] = args.data_dir
    # Importing bot happens above for library use; rebuild its paths for CLI overrides.
    if args.data_dir:
        bot.ROOT = Path(args.data_dir)
        bot.BIN = bot.ROOT / "bin" / "wechat_ax"
        bot.STATE = bot.ROOT / "state" / "state.json"
        bot.LOCK = bot.ROOT / "state" / "bot.lock"
        bot.RUNTIME = bot.ROOT / "run"
        globals()["HOME"] = bot.ROOT
        globals()["CONFIG"] = HOME / "state" / "config.json"
        globals()["RECORDS"] = HOME / "state" / "records.json"
        globals()["MEMORY"] = HOME / "state" / "memory.md"
    main(args.port)
