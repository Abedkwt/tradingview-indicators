#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ABED_TV_LOCAL_BRIDGE_v1.py

Purpose:
- Receive TradingView webhook JSON.
- Validate secret and payload.
- Write ABED_TV_SIGNAL.json into MT5 Common Files folder.
- Let ABED_XAUUSD_TV_EXECUTOR_PRO_v1_1 EA read the file and execute.

Important:
- This bridge does NOT trade by itself.
- MT5 EA remains the executor.
- TradingView/Pine remains the strategy brain.
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from datetime import datetime
import json
import os
import csv
import argparse
import tempfile

DEFAULT_SECRET = "ABED_SECRET_2026"
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8787
SIGNAL_FILE_NAME = "ABED_TV_SIGNAL.json"
LOG_FILE_NAME = "ABED_TV_BRIDGE_LOG.csv"

ALLOWED_ACTIONS = {
    "BUY",
    "SELL",
    "CLOSE_ALL",
    "CLOSE_BUY",
    "CLOSE_SELL",
    "MANAGE",
    "ADD_BUY",
    "ADD_SELL",
}

REQUIRED_TRADE_FIELDS = ("secret", "action", "alert_id")


def mt5_common_files_path() -> Path:
    appdata = os.environ.get("APPDATA")
    if not appdata:
        raise RuntimeError("APPDATA environment variable not found. Are you running this on Windows?")
    return Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"


def now_text() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def json_response(handler: BaseHTTPRequestHandler, status_code: int, payload: dict) -> None:
    raw = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
    handler.send_response(status_code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.end_headers()
    handler.wfile.write(raw)


def write_log(log_path: Path, level: str, message: str, payload: dict | None = None) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    exists = log_path.exists()

    with log_path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        if not exists:
            writer.writerow(["time", "level", "message", "action", "alert_id", "symbol", "timeframe"])
        writer.writerow([
            now_text(),
            level,
            message,
            str((payload or {}).get("action", "")),
            str((payload or {}).get("alert_id", "")),
            str((payload or {}).get("symbol", "")),
            str((payload or {}).get("timeframe", "")),
        ])


def normalize_payload(payload: dict) -> dict:
    clean = dict(payload)

    if "action" in clean:
        clean["action"] = str(clean["action"]).upper().strip()

    for key in ("entry", "sl", "tp1", "tp2", "risk_percent"):
        if key in clean and clean[key] not in ("", None):
            try:
                clean[key] = float(clean[key])
            except (TypeError, ValueError):
                raise ValueError(f"Invalid numeric field: {key}={clean[key]}")

    clean.setdefault("strategy", "CLEAN_LABELS_v6")
    clean.setdefault("symbol", "XAUUSD")
    clean.setdefault("timeframe", "5M")
    clean.setdefault("reason", "TRADINGVIEW_WEBHOOK")

    return clean


def validate_payload(payload: dict, expected_secret: str) -> None:
    for field in REQUIRED_TRADE_FIELDS:
        if field not in payload or str(payload[field]).strip() == "":
            raise ValueError(f"Missing required field: {field}")

    if str(payload.get("secret", "")) != expected_secret:
        raise ValueError("Secret mismatch")

    action = str(payload.get("action", "")).upper().strip()
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"Unsupported action: {action}")

    if action in ("BUY", "SELL"):
        for field in ("sl", "tp1", "tp2"):
            if field not in payload:
                raise ValueError(f"Missing required field for {action}: {field}")

        entry = payload.get("entry", None)
        sl = payload.get("sl", None)
        tp1 = payload.get("tp1", None)
        tp2 = payload.get("tp2", None)

        if entry is not None:
            if action == "BUY":
                if not (sl < entry and tp1 > entry and tp2 > entry):
                    raise ValueError("BUY sanity failed: SL must be below entry, TP1/TP2 above entry")
            if action == "SELL":
                if not (sl > entry and tp1 < entry and tp2 < entry):
                    raise ValueError("SELL sanity failed: SL must be above entry, TP1/TP2 below entry")


def atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8", dir=str(path.parent), suffix=".tmp") as tmp:
        json.dump(payload, tmp, ensure_ascii=False, indent=2)
        tmp.write("\n")
        temp_name = tmp.name

    os.replace(temp_name, path)


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "ABED_TV_LOCAL_BRIDGE_v1"

    def do_GET(self):
        if self.path in ("/", "/health"):
            json_response(self, 200, {
                "ok": True,
                "service": "ABED_TV_LOCAL_BRIDGE_v1",
                "message": "Bridge is running",
                "signal_file": str(self.server.signal_path),
                "log_file": str(self.server.log_path),
                "time": now_text(),
            })
            return

        json_response(self, 404, {"ok": False, "error": "Not found"})

    def do_POST(self):
        if self.path not in ("/tv-signal", "/webhook", "/"):
            json_response(self, 404, {"ok": False, "error": "Wrong endpoint. Use /tv-signal"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")

            if not raw.strip():
                raise ValueError("Empty body")

            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError("Payload must be a JSON object")

            payload = normalize_payload(payload)
            validate_payload(payload, self.server.secret)

            atomic_write_json(self.server.signal_path, payload)
            write_log(self.server.log_path, "OK", "Signal written to MT5 Common Files", payload)

            json_response(self, 200, {
                "ok": True,
                "message": "Signal accepted and written",
                "alert_id": payload.get("alert_id"),
                "action": payload.get("action"),
                "signal_file": str(self.server.signal_path),
            })

        except Exception as exc:
            write_log(self.server.log_path, "ERROR", str(exc), {})
            json_response(self, 400, {
                "ok": False,
                "error": str(exc),
            })

    def log_message(self, fmt, *args):
        print(f"[{now_text()}] {self.address_string()} - {fmt % args}")


def main():
    parser = argparse.ArgumentParser(description="ABED TradingView to MT5 local bridge v1")
    parser.add_argument("--host", default=DEFAULT_HOST, help="Host to listen on. Default 0.0.0.0")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port to listen on. Default 8787")
    parser.add_argument("--secret", default=DEFAULT_SECRET, help="Shared secret expected in TradingView JSON")
    parser.add_argument("--output-dir", default="", help="MT5 Common Files path. Leave empty for auto-detect.")
    args = parser.parse_args()

    if args.output_dir.strip():
        output_dir = Path(args.output_dir).expanduser()
    else:
        output_dir = mt5_common_files_path()

    signal_path = output_dir / SIGNAL_FILE_NAME
    log_path = output_dir / LOG_FILE_NAME

    server = HTTPServer((args.host, args.port), BridgeHandler)
    server.secret = args.secret
    server.signal_path = signal_path
    server.log_path = log_path

    print("=" * 70)
    print("ABED TV LOCAL BRIDGE v1")
    print("=" * 70)
    print(f"Listening on: http://{args.host}:{args.port}")
    print(f"Webhook endpoint: http://127.0.0.1:{args.port}/tv-signal")
    print(f"MT5 signal file: {signal_path}")
    print(f"Bridge log file:  {log_path}")
    print("Press CTRL+C to stop.")
    print("=" * 70)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nBridge stopped.")


if __name__ == "__main__":
    main()
