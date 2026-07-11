#!/usr/bin/env python3
"""flac2wav — local web app that converts FLAC to WAV (LPCM 16-bit / 44.1 kHz)
for the Pioneer DEH-80PRS. Python stdlib only; requires ffmpeg + ffprobe.

Usage:  python3 app.py [--port 8574] [--no-browser]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATIC = Path(__file__).resolve().parent / "static"


# --------------------------------------------------------------------------- #
# ffmpeg helpers
# --------------------------------------------------------------------------- #
def effective_outdir(raw: str) -> Path:
    """Resolve the destination and ensure files land in a `wav` subfolder.
    Selecting a folder that is already named `wav` won't nest a second one."""
    d = Path(os.path.expanduser(raw or str(Path.home()))).resolve()
    if d.name.lower() != "wav":
        d = d / "wav"
    return d


def require_tools():
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            sys.exit(f"error: {tool} not found. Install it first (e.g. sudo apt install ffmpeg)")


def is_real_flac(path: Path) -> bool:
    """Magic bytes + a decodable FLAC audio stream (extension alone can lie)."""
    try:
        with open(path, "rb") as fh:
            if fh.read(4) != b"fLaC":
                return False
    except OSError:
        return False
    try:
        codec = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=codec_name",
             "-of", "default=noprint_wrappers=1:nokey=1", "--", str(path)],
            capture_output=True, text=True, timeout=15).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return False
    return codec == "flac"


def probe_info(path: Path) -> dict:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=sample_rate,bits_per_raw_sample:format=duration",
             "-of", "json", "--", str(path)],
            capture_output=True, text=True, timeout=15).stdout
        data = json.loads(out)
        stream = (data.get("streams") or [{}])[0]
        return {
            "rate": int(stream.get("sample_rate") or 0),
            "bits": int(stream.get("bits_per_raw_sample") or 0) or None,
            "duration": float(data.get("format", {}).get("duration") or 0),
            "size": path.stat().st_size,
        }
    except Exception:
        return {"rate": 0, "bits": None, "duration": 0, "size": 0}


# --------------------------------------------------------------------------- #
# conversion job
# --------------------------------------------------------------------------- #
class Job:
    def __init__(self, files, outdir: Path, overwrite: bool):
        self.outdir = outdir
        self.overwrite = overwrite
        self.cancel = threading.Event()
        self.lock = threading.Lock()
        self.items = [{"src": f, "state": "pending", "percent": 0, "out": "", "error": ""}
                      for f in files]
        self.running = True
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def status(self):
        with self.lock:
            done = sum(1 for i in self.items if i["state"] == "done")
            failed = sum(1 for i in self.items if i["state"] == "failed")
            skipped = sum(1 for i in self.items if i["state"] == "skipped")
            return {"running": self.running, "done": done, "failed": failed,
                    "skipped": skipped, "total": len(self.items),
                    "items": [dict(i) for i in self.items]}

    def _unique_out(self, src: Path, used: set) -> Path:
        base = src.stem
        candidate = self.outdir / f"{base}.wav"
        n = 2
        while str(candidate) in used or (candidate.exists() and not self.overwrite
                                         and str(candidate) not in used):
            # existing file: only suffix when it collides with another queued name;
            # a pre-existing file means "skip" (handled by caller) unless overwrite
            break
        while str(candidate) in used:
            candidate = self.outdir / f"{base} ({n}).wav"
            n += 1
        return candidate

    def _run(self):
        self.outdir.mkdir(parents=True, exist_ok=True)
        used = set()
        for item in self.items:
            if self.cancel.is_set():
                with self.lock:
                    item["state"] = "cancelled"
                continue
            src = Path(item["src"])
            with self.lock:
                item["state"] = "converting"
            if not src.is_file() or not is_real_flac(src):
                with self.lock:
                    item["state"] = "failed"
                    item["error"] = "not a real FLAC file"
                continue
            out = self._unique_out(src, used)
            if out.exists() and not self.overwrite:
                with self.lock:
                    item["state"] = "skipped"
                    item["out"] = str(out)
                continue
            used.add(str(out))
            duration = probe_info(src)["duration"] or 0
            ok = self._convert(src, out, duration, item)
            with self.lock:
                if ok:
                    item["state"] = "done"
                    item["percent"] = 100
                    item["out"] = str(out)
                else:
                    if not self.cancel.is_set():
                        item["state"] = "failed"
                        item["error"] = item["error"] or "ffmpeg error"
                    else:
                        item["state"] = "cancelled"
                    out.unlink(missing_ok=True)
        self.running = False

    def _convert(self, src: Path, out: Path, duration: float, item) -> bool:
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-i", str(src), "-vn", "-map_metadata", "0",
               "-af", "aresample=out_sample_rate=44100:out_sample_fmt=s16:"
                      "dither_method=triangular_hp",
               "-c:a", "pcm_s16le",
               "-progress", "pipe:1", "-nostats", "--", str(out)]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
        except OSError as exc:
            item["error"] = str(exc)
            return False
        for line in proc.stdout:
            if self.cancel.is_set():
                proc.terminate()
                proc.wait(timeout=5)
                return False
            m = re.match(r"out_time_us=(\d+)", line)
            if m and duration > 0:
                pct = min(99, int(int(m.group(1)) / 1_000_000 / duration * 100))
                with self.lock:
                    item["percent"] = pct
        proc.wait()
        if proc.returncode != 0:
            item["error"] = (proc.stderr.read() or "").strip()[:300]
        return proc.returncode == 0


JOB = None  # single active job


# --------------------------------------------------------------------------- #
# HTTP handler
# --------------------------------------------------------------------------- #
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(STATIC), **kw)

    def log_message(self, *a):  # quiet
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    # ------------------------------ GET ------------------------------ #
    def do_GET(self):
        if self.path == "/api/defaults":
            home = Path.home()
            return self._json({"home": str(home),
                               "outdir": str(home / "Music")})
        if self.path == "/api/progress":
            return self._json(JOB.status() if JOB else {"running": False, "items": []})
        return super().do_GET()

    # ------------------------------ POST ----------------------------- #
    def do_POST(self):
        global JOB
        try:
            data = self._body()
        except (ValueError, OSError):
            return self._json({"error": "bad request"}, 400)

        if self.path == "/api/browse":
            raw = data.get("path") or str(Path.home())
            path = Path(os.path.expanduser(raw)).resolve()
            if not path.is_dir():
                return self._json({"error": "not a folder"}, 404)
            dirs, flacs = [], []
            try:
                for entry in sorted(path.iterdir(), key=lambda p: p.name.lower()):
                    if entry.name.startswith("."):
                        continue
                    if entry.is_dir():
                        dirs.append(entry.name)
                    elif entry.suffix.lower() == ".flac":
                        flacs.append(entry.name)
            except PermissionError:
                return self._json({"error": "permission denied"}, 403)
            return self._json({"path": str(path),
                               "parent": str(path.parent) if path.parent != path else None,
                               "dirs": dirs, "flacs": flacs})

        if self.path == "/api/inspect":
            results = []
            for raw in data.get("paths", []):
                p = Path(os.path.expanduser(raw)).resolve()
                entry = {"path": str(p), "name": p.name, "folder": str(p.parent),
                         "valid": p.is_file() and is_real_flac(p)}
                if entry["valid"]:
                    entry.update(probe_info(p))
                results.append(entry)
            return self._json({"files": results})

        if self.path == "/api/convert":
            if JOB and JOB.running:
                return self._json({"error": "a conversion is already running"}, 409)
            files = data.get("files", [])
            if not files:
                return self._json({"error": "nothing to convert"}, 400)
            outdir = effective_outdir(data.get("outdir"))
            JOB = Job(files, outdir, bool(data.get("overwrite")))
            return self._json({"ok": True, "outdir": str(outdir)})

        if self.path == "/api/cancel":
            if JOB:
                JOB.cancel.set()
            return self._json({"ok": True})

        if self.path == "/api/reveal":
            folder = effective_outdir(data.get("path"))
            if folder.is_dir():
                opener = ("open" if sys.platform == "darwin" else "xdg-open")
                subprocess.Popen([opener, str(folder)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return self._json({"ok": True})
            return self._json({"error": "folder not found"}, 404)

        return self._json({"error": "unknown endpoint"}, 404)


def main():
    parser = argparse.ArgumentParser(description="flac2wav web app")
    parser.add_argument("--port", type=int, default=8574)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    require_tools()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}"
    print(f"flac2wav running at {url}  (Ctrl+C to stop)")
    if not args.no_browser:
        threading.Timer(0.6, webbrowser.open, [url]).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
