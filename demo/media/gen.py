#!/usr/bin/env python3
"""B-roll + music generator for the GCT demo reel (OpenRouter, stdlib only).

    shots.json --> gen.py shot <id> --> budget guard --> OpenRouter --> ~/Movies/GCT Reel/

Run:  source ~/.zprofile && python3 -I demo/media/gen.py <command> ...
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from enum import Enum
from pathlib import Path

# --- Endpoints ---------------------------------------------------------------
API = "https://openrouter.ai/api/v1"
CREDITS_URL = f"{API}/credits"
VIDEOS_URL = f"{API}/videos"
VIDEO_MODELS_URL = f"{API}/videos/models"
IMAGES_URL = f"{API}/images"
CHAT_URL = f"{API}/chat/completions"

# --- Defaults ----------------------------------------------------------------
VIDEO_MODEL = "google/veo-3.1-fast"
IMAGE_MODEL = "google/gemini-3-pro-image"
MUSIC_MODEL = "google/lyria-3-pro-preview"
ASPECT = "16:9"

# Lyria lists $0 token pricing; the model page bills a flat $0.08 per song.
MUSIC_PRICE_USD = 0.08

# Gemini 3 Pro Image bills image_output per token; Google's docs: 1K/2K = 1120, 4K = 2000.
IMAGE_TOKENS = {"1K": 1120, "2K": 1120, "4K": 2000}
IMAGE_TOKEN_USD = 0.00012

# --- Paths -------------------------------------------------------------------
HERE = Path(__file__).resolve().parent
SHOTS_FILE = HERE / "shots.json"
LEDGER_FILE = HERE / "spend.json"
REEL_DIR = Path.home() / "Movies" / "GCT Reel"
STOCK_DIR = REEL_DIR / "stock"
KEYFRAME_DIR = STOCK_DIR / "keyframes"
MUSIC_DIR = REEL_DIR / "music"

POLL_SECONDS = 15
HTTP_ACCEPTED = 202


class Status(str, Enum):
    PENDING = "pending"
    RUNNING = "in_progress"
    DONE = "completed"
    FAILED = "failed"


class Kind(str, Enum):
    VIDEO = "video"
    IMAGE = "image"
    MUSIC = "music"


class Overwrite(Enum):
    SKIP = 0
    FORCE = 1


# --- HTTP --------------------------------------------------------------------
def _key() -> str:
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        sys.exit("OPENROUTER_API_KEY not set (source ~/.zprofile)")
    return key


def _request(url: str, body: dict | None = None) -> urllib.request.Request:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")

    # Unredirected: the key never follows a redirect to a storage host.
    req.add_unredirected_header("Authorization", f"Bearer {_key()}")
    if data:
        req.add_header("Content-Type", "application/json")
    return req


def http_json(url: str, body: dict | None = None, timeout: int = 120) -> dict:
    try:
        with urllib.request.urlopen(_request(url, body), timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        sys.exit(f"HTTP {err.code} {url}: {err.read().decode(errors='replace')[:800]}")


def http_bytes(url: str, timeout: int = 600) -> bytes:
    with urllib.request.urlopen(_request(url), timeout=timeout) as resp:
        return resp.read()


# --- Budget ------------------------------------------------------------------
def usage() -> float:
    return float(http_json(CREDITS_URL)["data"]["total_usage"])


def credits() -> tuple[float, float]:
    data = http_json(CREDITS_URL)["data"]
    return float(data["total_usage"]), float(data["total_credits"])


def _ledger() -> dict:
    if not LEDGER_FILE.exists():
        sys.exit(f"no ledger; run: gen.py budget --cap <usd>")
    return json.loads(LEDGER_FILE.read_text())


def _save_ledger(ledger: dict) -> None:
    LEDGER_FILE.write_text(json.dumps(ledger, indent=2) + "\n")


def spent(ledger: dict) -> float:
    # Credits lag behind async jobs, so trust whichever is larger: measured or estimated.
    measured = usage() - ledger["baseline_usage"]
    estimated = sum(e["est_usd"] for e in ledger["entries"])
    return max(measured, estimated)


def guard(label: str, est: float) -> None:
    ledger = _ledger()
    so_far = spent(ledger)
    if so_far + est > ledger["cap_usd"]:
        sys.exit(f"REFUSED {label}: ${so_far:.2f} spent + ${est:.2f} > cap ${ledger['cap_usd']:.2f}")

    ledger["entries"].append({"label": label, "est_usd": round(est, 4)})
    _save_ledger(ledger)
    print(f"[budget] {label}: est ${est:.2f}, spent so far ${so_far:.2f} / ${ledger['cap_usd']:.2f}")


def report() -> None:
    ledger = _ledger()
    used, total = credits()
    delta = used - ledger["baseline_usage"]
    print(f"[credits] delta ${delta:.4f}  remaining ${total - used:.4f}")


# --- Cost estimates ----------------------------------------------------------
def video_cost(model: str, seconds: int, res: str) -> float:
    models = http_json(VIDEO_MODELS_URL)["data"]
    skus = next((m["pricing_skus"] for m in models if m["id"] == model), None)
    if skus is None:
        sys.exit(f"unknown video model {model}")

    # SKU names: duration_seconds_without_audio[_720p|_4k]; 1080p has no suffix.
    suffix = {"720p": "_720p", "1080p": "", "4K": "_4k"}.get(res)
    sku = f"duration_seconds_without_audio{suffix}" if suffix is not None else None
    if sku not in skus:
        sys.exit(f"no price for {model} {res}; refusing to guess")
    return float(skus[sku]) * seconds


def image_cost(res: str) -> float:
    return IMAGE_TOKENS[res] * IMAGE_TOKEN_USD


# --- Video -------------------------------------------------------------------
def _data_url(path: Path) -> str:
    mime = "image/jpeg" if path.suffix.lower() in (".jpg", ".jpeg") else "image/png"
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"


def _frames(first: Path | None, last: Path | None) -> list[dict]:
    pairs = [("first_frame", first), ("last_frame", last)]
    return [
        {"type": "image_url", "image_url": {"url": _data_url(p)}, "frame_type": kind}
        for kind, p in pairs
        if p is not None
    ]


def submit(shot_id: str, model: str, prompt: str, seconds: int, res: str,
           first: Path | None = None, last: Path | None = None) -> str:
    guard(shot_id, video_cost(model, seconds, res))
    body = {
        "model": model,
        "prompt": prompt,
        "duration": seconds,
        "resolution": res,
        "aspect_ratio": ASPECT,
        "generate_audio": False,
    }
    frames = _frames(first, last)
    if frames:
        body["frame_images"] = frames

    job = http_json(VIDEOS_URL, body)
    _job_file(shot_id).write_text(json.dumps(job, indent=2) + "\n")
    print(f"[video] {shot_id} submitted job {job['id']} ({job['status']})")
    return job["id"]


def _job_file(shot_id: str) -> Path:
    return STOCK_DIR / f"{shot_id}.job.json"


def poll(job_id: str) -> dict:
    while True:
        job = http_json(f"{VIDEOS_URL}/{job_id}")
        status = job["status"]
        if status == Status.DONE:
            return job
        if status == Status.FAILED:
            sys.exit(f"[video] job {job_id} failed: {job.get('error')}")
        print(f"[video] {job_id} {status}...", flush=True)
        time.sleep(POLL_SECONDS)


def download(job_id: str, out: Path) -> Path:
    out.write_bytes(http_bytes(f"{VIDEOS_URL}/{job_id}/content?index=0"))
    print(f"[video] saved {out} ({out.stat().st_size / 1e6:.1f} MB)")
    return out


# --- Image -------------------------------------------------------------------
def image(label: str, prompt: str, out: Path, res: str = "4K", model: str = IMAGE_MODEL,
          refs: list[Path] | None = None) -> Path:
    guard(label, image_cost(res))
    body = {"model": model, "prompt": prompt, "resolution": res, "aspect_ratio": ASPECT}

    # Reference images turn this into an edit, e.g. fixing a misspelled word.
    if refs:
        body["input_references"] = [{"type": "image_url", "image_url": {"url": _data_url(r)}} for r in refs]
    resp = http_json(IMAGES_URL, body, timeout=300)

    item = resp["data"][0]
    ext = ".jpg" if "jpeg" in item.get("media_type", "") else ".png"
    out = out.with_suffix(ext)
    out.write_bytes(base64.b64decode(item["b64_json"]))
    print(f"[image] saved {out} (reported cost ${resp.get('usage', {}).get('cost', '?')})")
    return out


# --- Music -------------------------------------------------------------------
def _sse_audio(resp) -> tuple[str, str]:
    # Audio arrives as base64 fragments in choices[0].delta.audio.data.
    chunks, fmt = [], "mp3"
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue

        event = json.loads(line[len("data:"):])
        if "error" in event:
            sys.exit(f"[music] stream error: {event['error']}")
        for choice in event.get("choices", []):
            audio = (choice.get("delta") or {}).get("audio") or {}
            chunks.append(audio.get("data") or "")
            fmt = audio.get("format", fmt)
    return "".join(chunks), fmt


def music(label: str, prompt: str, out: Path, model: str = MUSIC_MODEL) -> Path:
    guard(label, MUSIC_PRICE_USD)
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "modalities": ["text", "audio"],
        "stream": True,
    }
    with urllib.request.urlopen(_request(CHAT_URL, body), timeout=600) as resp:
        b64, fmt = _sse_audio(resp)

    if not b64:
        sys.exit("[music] no audio in response")
    out = out.with_suffix(f".{fmt}")
    out.write_bytes(base64.b64decode(b64))
    print(f"[music] saved {out} ({out.stat().st_size / 1e6:.1f} MB)")
    return out


# --- Shots -------------------------------------------------------------------
def _shots() -> dict[str, dict]:
    return {s["id"]: s for s in json.loads(SHOTS_FILE.read_text())["shots"]}


def _shot_out(shot: dict) -> Path:
    if shot["kind"] == Kind.IMAGE:
        return KEYFRAME_DIR / shot["id"]
    if shot["kind"] == Kind.MUSIC:
        return MUSIC_DIR / shot["id"]
    return STOCK_DIR / f"{shot['id']}.mp4"


def _existing(shot: dict) -> Path | None:
    out = _shot_out(shot)
    if out.suffix:
        return out if out.exists() else None
    return next(iter(sorted(out.parent.glob(f"{out.name}.*"))), None)


def _frame_path(ref: str | None) -> Path | None:
    # A frame is a file path or the id of an image shot in shots.json.
    if ref is None:
        return None
    if Path(ref).expanduser().exists():
        return Path(ref).expanduser()

    found = _existing(_shots()[ref])
    if found is None:
        sys.exit(f"frame '{ref}' not generated yet (run: gen.py shot {ref})")
    return found


def run_shot(shot_id: str, mode: Overwrite = Overwrite.SKIP) -> None:
    shot = _shots()[shot_id]
    done = _existing(shot)
    if done and mode is Overwrite.SKIP:
        print(f"[skip] {shot_id} exists: {done}")
        return

    kind = shot["kind"]
    if kind == Kind.IMAGE:
        refs = [_frame_path(r) for r in shot.get("refs", [])]
        image(shot_id, shot["prompt"], _shot_out(shot), shot.get("resolution", "4K"), shot["model"], refs)
    elif kind == Kind.MUSIC:
        music(shot_id, shot["prompt"], _shot_out(shot), shot["model"])
    else:
        _run_video(shot)
    report()


def _run_video(shot: dict) -> None:
    frames = shot.get("frames") or {}
    first, last = _frame_path(frames.get("first")), _frame_path(frames.get("last"))
    job_id = submit(shot["id"], shot["model"], shot["prompt"], shot["duration"],
                    shot["resolution"], first, last)
    poll(job_id)
    download(job_id, _shot_out(shot))


# --- CLI ---------------------------------------------------------------------
def _cli() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("budget", help="start a spend ledger at current usage")
    b.add_argument("--cap", type=float, required=True)
    sub.add_parser("credits", help="print delta + remaining credit")

    s = sub.add_parser("submit", help="submit a raw video job")
    s.add_argument("id")
    s.add_argument("prompt")
    s.add_argument("--model", default=VIDEO_MODEL)
    s.add_argument("--duration", type=int, default=4, choices=[4, 6, 8])
    s.add_argument("--resolution", default="720p")
    s.add_argument("--first", type=Path)
    s.add_argument("--last", type=Path)

    sub.add_parser("poll", help="wait for a video job").add_argument("job_id")
    d = sub.add_parser("download", help="download a finished video job")
    d.add_argument("job_id")
    d.add_argument("out", type=Path)

    i = sub.add_parser("image", help="generate a keyframe image")
    i.add_argument("id")
    i.add_argument("prompt")
    i.add_argument("--resolution", default="4K", choices=list(IMAGE_TOKENS))
    i.add_argument("--ref", type=Path, action="append", help="reference image to edit")

    m = sub.add_parser("music", help="generate a music track")
    m.add_argument("id")
    m.add_argument("prompt")

    r = sub.add_parser("shot", help="run shots from shots.json end to end")
    r.add_argument("ids", nargs="+")
    r.add_argument("--force", action="store_true", help="regenerate even if output exists")
    return p


def main() -> None:
    args = _cli().parse_args()
    for d in (STOCK_DIR, KEYFRAME_DIR, MUSIC_DIR):
        d.mkdir(parents=True, exist_ok=True)

    if args.cmd == "budget":
        _save_ledger({"baseline_usage": usage(), "cap_usd": args.cap, "entries": []})
        report()
        return
    if args.cmd == "credits":
        report()
        return
    if args.cmd == "submit":
        submit(args.id, args.model, args.prompt, args.duration, args.resolution, args.first, args.last)
        return
    if args.cmd == "poll":
        print(json.dumps(poll(args.job_id).get("usage"), indent=2))
        report()
        return
    if args.cmd == "download":
        download(args.job_id, args.out)
        return
    if args.cmd == "image":
        image(args.id, args.prompt, KEYFRAME_DIR / args.id, args.resolution, refs=args.ref)
        report()
        return
    if args.cmd == "music":
        music(args.id, args.prompt, MUSIC_DIR / args.id)
        report()
        return

    mode = Overwrite.FORCE if args.force else Overwrite.SKIP
    for shot_id in args.ids:
        run_shot(shot_id, mode)


if __name__ == "__main__":
    main()
