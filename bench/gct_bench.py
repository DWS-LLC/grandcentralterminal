#!/usr/bin/env python3
"""GCT brutal benchmark suite — hammer GCT at extreme conditions.

Two targets:
  isolated (default): spins its own gctd in a tmpdir (GCT_SOCK override),
    safe to run anytime; measures daemon+PTY+socket path only.
  live (--live): drives YOUR RUNNING session's daemon socket. Every created
    pane OPENS A REAL WINDOW on the canvas (makePaneView on paneCreated) and
    all its output RENDERS through libghostty/Metal — this is the GPU test.
    Panes are tracked and closed at each scenario's end; but it WILL thrash
    your visible canvas and rewrite layout state. Don't run live mid-demo.

Drives the daemon wire protocol directly (no synthetic GUI events): opens/
closes hundreds of panes, floods them with output (cat /dev/urandom, yes,
htop/btop), fires simultaneous resize/move storms, and samples RSS/CPU/
fds/threads throughout. In live mode also samples the app process + GPU.

Usage:
    python3 bench/gct_bench.py --suite smoke        # quick sanity (~30s)
    python3 bench/gct_bench.py --suite standard     # full baseline (~5 min)
    python3 bench/gct_bench.py --suite brutal       # boundary hunt (~15 min)
    python3 bench/gct_bench.py --suite backpressure # slow-subscriber wedge
    python3 bench/gct_bench.py --live --suite smoke # SAME but on your canvas
    python3 bench/gct_bench.py --list               # list scenarios

Results: JSON report in bench/results/<ts>_<suite>.json + summary on stdout.
Compares against bench/baseline.json when present (set with --set-baseline).

Requirements: built gctd+ptyexec in .build/release, python psutil.
"""
import argparse
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GCTD = os.path.join(REPO, ".build", "release", "gctd")
PTYEXEC = os.path.join(REPO, ".build", "release", "ptyexec")
LIVE_SOCK = os.path.expanduser(
    "~/Library/Application Support/Grand Central Terminal/daemon.sock")

# Live mode: the app renders every pane we create, so keep the window count
# survivable for the GPU path and recompute rects per scenario below. These
# caps apply ONLY in live mode (isolated mode uses the suite kwargs as-is).
# Chaos-grid default: 50x50 (2500 panes) would OOM the app; start 10x10
# (100) and scale only if FPS holds. Override with --grid N.
CHAOS_DEFAULT_GRID = 10
T_HELLO, T_CREATE, T_ATTACH, T_INPUT = 1, 2, 3, 4
T_RESIZE, T_DETACH, T_CLOSE, T_RENAME = 5, 6, 7, 8
T_LIST, T_KILL = 9, 10
T_MOVE, T_CWD = 11, 12
T_WELCOME, T_CREATED, T_META = 64, 65, 66
T_OUTPUT, T_EXIT, T_LIST_R, T_ERROR = 67, 68, 69, 70


class FPSMeter(threading.Thread):
    """True display FPS: md5 each captured frame, count CHANGES per second.

    mss grabs at ~55-83fps; a changed hash = the compositor presented a new
    frame. Idle canvas reads ~0; saturated canvas reads up to the grab rate
    (cap, not the display rate — relative comparison across chaos iters is
    what matters). Full-screen grabs; ~13ms each on this machine.
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.stop_ev = threading.Event()
        self.series = []  # (t, changed_bool)
        self.grab_rate = 0.0

    def run(self):
        try:
            from mss import MSS
            import hashlib
        except ImportError:
            return
        try:
            with MSS() as s:
                mon = s.monitors[1]
                prev = None
                n = 0
                t0 = time.time()
                while not self.stop_ev.is_set():
                    img = s.grab(mon)
                    h = hashlib.md5(img.rgb).digest()
                    self.series.append((time.time(), prev is not None
                                        and h != prev))
                    prev = h
                    n += 1
                self.grab_rate = n / max(0.001, time.time() - t0)
        except Exception:
            return

    def stop(self):
        self.stop_ev.set()

    def fps_in(self, t0, t1):
        """Changed frames per second inside [t0, t1], clamped to the
        measured grab rate (above that = sampling artifact, not display)."""
        n = sum(1 for t, c in self.series if t0 <= t <= t1 and c)
        raw = n / max(0.001, t1 - t0)
        cap = self.grab_rate if self.grab_rate > 0 else raw
        return min(raw, cap)
class Client:
    """One connection with a background reader thread feeding a frame queue.

    Sends and receives are decoupled so interleaved broadcasts (paneMeta,
    paneExit, ...) can never desync a request/response pair: use wait_for()
    to pick out the frame you want. The reader also keeps the socket drained
    at all times — a client that sends without reading will eventually wedge
    the daemon's broadcast path (blocking writes under the server lock),
    which is a daemon bug, not a harness bug (see sc_slow_subscriber).
    Pass reader=False for a deliberate black-hole client.
    """

    def __init__(self, sock, reader=True):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(30)
        self.s.connect(sock)
        self.lock = threading.Lock()
        self.q = []
        self.cond = threading.Condition()
        self.closed = False
        self.reader = None
        if reader:
            self.reader = threading.Thread(target=self._run, daemon=True)
            self.reader.start()

    def _run(self):
        try:
            while True:
                hdr = self._read(4)
                (n,) = struct.unpack(">I", hdr)
                if n < 1 or n > 32 << 20:
                    return
                p = self._read(n)
                with self.cond:
                    self.q.append((p[0], p[1:]))
                    self.cond.notify_all()
        except (OSError, IOError):
            return
        finally:
            with self.cond:
                self.cond.notify_all()

    def _read(self, n):
        buf = b""
        while len(buf) < n:
            try:
                c = self.s.recv(n - len(buf))
            except socket.timeout:
                if self.closed:
                    raise IOError("closed")
                continue
            if not c:
                raise IOError("eof")
            buf += c
        return buf

    def send(self, tag, payload: bytes):
        msg = bytes([tag]) + payload
        with self.lock:
            self.s.sendall(struct.pack(">I", len(msg)) + msg)

    def send_json(self, tag, obj):
        self.send(tag, json.dumps(obj).encode())

    def next_frame(self, timeout=30):
        """Oldest queued frame, or None on timeout. Never raises for empty."""
        if self.reader is None:
            time.sleep(timeout)
            return None
        end = time.time() + timeout
        with self.cond:
            while not self.q:
                if self.closed:
                    return None
                wait = end - time.time()
                if wait <= 0:
                    return None
                self.cond.wait(wait)
            return self.q.pop(0)

    def recv(self, timeout=30):
        f = self.next_frame(timeout=timeout)
        if f is None:
            raise IOError("timeout")
        return f

    def wait_for(self, pred, timeout=30):
        """First frame matching pred; non-matching frames are skipped."""
        end = time.time() + timeout
        skipped = []
        try:
            while True:
                f = self.next_frame(max(0.0, end - time.time()))
                if f is None:
                    raise IOError("timeout waiting for frame")
                if pred(f[0], f[1]):
                    return f
                skipped.append(f)
        finally:
            if skipped:
                with self.cond:
                    self.q = skipped + self.q

    def drain_welcome(self, timeout=30):
        tag, _ = self.wait_for(lambda t, b: t in (T_WELCOME, T_LIST_R),
                               timeout=timeout)
        return tag

    def list_panes(self, timeout=30):
        self.send_json(T_LIST, {"version": 1})
        tag, body = self.wait_for(lambda t, b: t in (T_WELCOME, T_LIST_R),
                                  timeout=timeout)
        return json.loads(body).get("panes", [])

    def close(self):
        self.closed = True
        with self.cond:
            self.cond.notify_all()
        try:
            self.s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.s.close()
        except OSError:
            pass


class Sink:
    """One persistent subscriber: attaches to every pane and drains output.

    A single connection carries all subscribes, so daemon -> client buffers
    never fill (a stalled subscriber would stall the daemon's fanOut) and
    delivered throughput is measurable. Attach snapshots (scrollback replay)
    also land here and count toward bytes.
    """

    def __init__(self, sock):
        self.c = Client(sock)
        self.c.drain_welcome()
        self.bytes = 0
        self.frames = 0
        self.stop_ev = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_ev.set()
        self.c.close()

    def _run(self):
        while not self.stop_ev.is_set():
            f = self.c.next_frame(timeout=1.0)
            if f is None:
                continue
            tag, body = f
            if tag == T_OUTPUT and len(body) >= 16:
                self.bytes += len(body) - 16
                self.frames += 1

    def attach(self, pane_id, cols=80, rows=24):
        try:
            self.c.send_json(T_ATTACH, {"id": pane_id, "cols": cols,
                                        "rows": rows})
        except (OSError, IOError):
            pass


def spawn_daemon(workdir):
    bindir = os.path.join(workdir, "bin")
    os.makedirs(bindir)
    shutil.copy(GCTD, os.path.join(bindir, "gctd"))
    shutil.copy(PTYEXEC, os.path.join(bindir, "ptyexec"))
    env = dict(os.environ,
               GCT_SOCK=os.path.join(workdir, "daemon.sock"),
               GCT_STATE=os.path.join(workdir, "state.json"),
               GCT_PID=os.path.join(workdir, "daemon.pid"))
    logf = open(os.path.join(workdir, "daemon.log"), "wb")
    p = subprocess.Popen([os.path.join(bindir, "gctd")],
                         stdout=logf, stderr=subprocess.STDOUT, env=env)
    # wait for bind
    for _ in range(100):
        if os.path.exists(env["GCT_SOCK"]):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(2)
                s.connect(env["GCT_SOCK"])
                s.close()
                break
            except OSError:
                pass
        time.sleep(0.05)
    else:
        p.kill()
        raise RuntimeError("daemon did not bind; see workdir daemon.log")
    return p, env


def sample_named(pid, prev=None):
    """psutil snapshot of one pid; cpu from cpu-time deltas (see sample()).
    Returns (dict_or_None, opaque_prev)."""
    import psutil
    now = time.time()
    try:
        p = psutil.Process(pid)
        mi = p.memory_info()
        tc = p.cpu_times()
        nf, nt = p.num_fds(), p.num_threads()
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None, None
    cpu = 0.0
    cur = {"t": now, "time": tc.user + tc.system}
    if prev is not None:
        dt = now - prev["t"]
        if dt > 0:
            cpu = max(0.0, cur["time"] - prev["time"]) / dt * 100.0
    return {"rss_mb": mi.rss / 1e6, "cpu_pct": cpu,
            "fds": nf, "threads": nt}, cur


def find_app_pid():
    """PID of the running GrandCentralTerminal app, or None."""
    import psutil
    for p in psutil.process_iter(["pid", "name", "cmdline"]):
        try:
            cmd = " ".join(p.info.get("cmdline") or [])
            if "GrandCentralTerminal" in cmd and "gct_bench" not in cmd:
                return p.info["pid"]
            if (p.info.get("name") or "") == "GrandCentralTerminal":
                return p.info["pid"]
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return None


def sample_gpu_once():
    """One GPU snapshot via powermetrics (needs sudo) or ioreg fallback.

    Returns {} when neither source is available — GPU numbers are
    best-effort, never fatal.
    """
    # Fast path: IOKit accelerator counters, no sudo needed.
    try:
        out = subprocess.run(
            ["ioreg", "-r", "-c", "IOAccelerator", "-a"],
            capture_output=True, timeout=5).stdout
        if out:
            import plistlib
            info = plistlib.loads(out)
            busy = []
            for dev in info if isinstance(info, list) else []:
                b = (dev.get("GPU Busy") or dev.get("gpu_busy")
                     or dev.get("InUse") or 0)
                try:
                    busy.append(float(b))
                except (TypeError, ValueError):
                    pass
            if busy:
                return {"gpu_busy": max(busy), "src": "ioreg"}
    except Exception:
        pass
    # Slow path: powermetrics needs root; try passwordless sudo only.
    try:
        out = subprocess.run(
            ["sudo", "-n", "powermetrics", "-n", "1", "-i", "500",
             "--samplers", "gpu_power", "-o", "-"],
            capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            if "GPU active" in line or "GPU frequency" in line:
                return {"gpu_line": line.strip(), "src": "powermetrics"}
    except Exception:
        pass
    return {}


def live_rects(n, cols=4, w=620.0, h=420.0, gap=30.0):
    """Tile n non-overlapping world rects so live panes don't fight the
    overlap resolver (allows measuring create throughput, not shoving)."""
    return [{"x": float((i % cols) * (w + gap)),
             "y": float((i // cols) * (h + gap)), "w": w, "h": h}
            for i in range(n)]


def sample(proc, prev=None):
    """One resource sample: daemon alone + whole tree (daemon + children).

    Daemon-only numbers isolate GCT's own cost; tree numbers include the
    spawned shells/flood children (dominated by yes/htop themselves).
    CPU comes from /proc-style cpu-time DELTAS against the previous sample
    (prev wall + per-pid times), so short-lived flood children that spawn
    and die between samples still count. interval=None percentages always
    read ~0 at 4Hz and must not be used.
    Returns (sample_dict, opaque_prev_for_next_call).
    """
    import psutil
    now = time.time()
    try:
        root = psutil.Process(proc.pid)
    except psutil.NoSuchProcess:
        return {"alive": False}, None
    try:
        children = root.children(recursive=True)
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        children = []
    procs = [root] + children
    rss, nfd, nthr = 0, 0, 0
    daemon_rss, daemon_fd, daemon_thr = 0, 0, 0
    cpu_times = {}  # pid -> (user+system); summed below vs prev
    for q in procs:
        try:
            mi = q.memory_info()
            nf = q.num_fds()
            nt = q.num_threads()
            tc = q.cpu_times()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
        rss += mi.rss
        nfd += nf
        nthr += nt
        cpu_times[q.pid] = tc.user + tc.system
        if q.pid == proc.pid:
            daemon_rss, daemon_fd, daemon_thr = mi.rss, nf, nt
    cur = {"t": now, "times": cpu_times}
    daemon_cpu = tree_cpu = 0.0
    if prev is not None:
        dt = now - prev["t"]
        if dt > 0:
            old = prev["times"]
            # Daemon alone: delta on the daemon pid (may be gone -> 0).
            if proc.pid in cpu_times and proc.pid in old:
                daemon_cpu = max(0.0, cpu_times[proc.pid] - old[proc.pid]) \
                    / dt * 100.0
            # Tree: sum deltas on surviving pids + full interval for new
            # pids (assume busy whole dt — overcounts brief idlers, but
            # flood children ARE busy, and undercounting was the old bug).
            for pid, t in cpu_times.items():
                if pid in old:
                    tree_cpu += max(0.0, t - old[pid])
                else:
                    tree_cpu += t  # newborn: whole-life time in ≤dt
            tree_cpu = tree_cpu / dt * 100.0
            ncpu = psutil.cpu_count() or 1
            daemon_cpu = min(daemon_cpu, 100.0 * ncpu)
            tree_cpu = min(tree_cpu, 100.0 * ncpu)
    sysm = psutil.virtual_memory()
    return {"alive": True,
            "rss_mb": daemon_rss / 1e6, "cpu_pct": daemon_cpu,
            "fds": daemon_fd, "threads": daemon_thr,
            "tree_rss_mb": rss / 1e6, "tree_cpu_pct": tree_cpu,
            "tree_fds": nfd, "tree_threads": nthr,
            "sys_mem_avail_gb": sysm.available / 1e9}, cur


class Sampler(threading.Thread):
    """Samples the daemon every interval; in live mode also the app + GPU."""
    def __init__(self, proc, interval=0.25, app_pid=None, gpu=False):
        super().__init__(daemon=True)
        self.proc, self.interval = proc, interval
        self.app_pid, self.gpu = app_pid, gpu
        self.series = []
        self.stop_ev = threading.Event()

    def run(self):
        import psutil
        prev = app_prev = named_prev = None
        app_pid = None
        if isinstance(self.proc, int):
            named_prev = None
        else:
            try:
                psutil.Process(self.proc.pid)
            except psutil.NoSuchProcess:
                return
            app_pid = self.app_pid
        if isinstance(self.proc, int):
            app_pid = self.proc  # live mode: proc IS the daemon pid
        while not self.stop_ev.wait(self.interval):
            if isinstance(self.proc, int):
                try:
                    s, named_prev = sample_named(self.proc, named_prev)
                    if s is None:
                        s = {"alive": False}
                    else:
                        s["alive"] = True
                        # tree_* mirror daemon-only in live mode (children
                        # belong to the user's session, not the bench).
                        s["tree_rss_mb"] = s["rss_mb"]
                        s["tree_cpu_pct"] = s["cpu_pct"]
                        s["tree_fds"] = s["fds"]
                        s["tree_threads"] = s["threads"]
                except Exception:
                    s = {"alive": False}
            else:
                try:
                    s, prev = sample(self.proc, prev)
                except TypeError:
                    # Old-tuple mismatch during dev reload; re-baseline.
                    s, prev = sample(self.proc, None)
            s["t"] = time.time()
            if app_pid and not isinstance(self.proc, int):
                a, app_prev = sample_named(app_pid, app_prev)
                if a is not None:
                    s["app"] = a
            if self.gpu:
                g = sample_gpu_once()
                if g:
                    s["gpu"] = g
            self.series.append(s)
            if not s["alive"]:
                break


def summarize(series):
    live = [s for s in series if s.get("alive")]
    if not live:
        return {"samples": 0}
    def stats(key):
        vs = sorted(s[key] for s in live)
        return {"p50": vs[len(vs) // 2], "p95": vs[int(len(vs) * 0.95)],
                "max": vs[-1]}
    out = {"samples": len(live)}
    for k in ("rss_mb", "cpu_pct", "fds", "threads"):
        out[k] = stats(k)  # daemon alone
    for k in ("tree_rss_mb", "tree_cpu_pct", "tree_fds", "tree_threads"):
        out[k] = stats(k)  # daemon + spawned children
    return out


# ---------------------------------------------------------------- scenarios

def sc_create_close_storm(sock, sink, n=200, batch=20, log=print, live=False):
    """Open/close churn: n panes created, some live concurrently."""
    c = Client(sock)
    c.drain_welcome()
    ids = []
    t0 = time.time()
    created = 0
    rects = live_rects(n) if live else None
    for i in range(n):
        rect = rects[i] if rects else {"x": 0, "y": 0, "w": 100, "h": 100}
        c.send_json(T_CREATE, {"rect": rect,
                               "cwd": "/tmp", "command": "/bin/sleep 30"})
        # Broadcasts for other panes may interleave; pick out ours by tag.
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        meta = json.loads(body)["meta"]
        ids.append(meta["id"])
        sink.attach(meta["id"])
        created += 1
        if len(ids) >= batch:
            for pid in ids:
                c.send_json(T_CLOSE, {"id": pid})
            # Drain the paneExit broadcasts (other tags may interleave).
            for _ in ids:
                try:
                    c.wait_for(lambda t, b: t == T_EXIT, timeout=10)
                except IOError:
                    break
            ids = []
        if created % 50 == 0:
            log(f"  churn {created}/{n}")
    for pid in ids:
        c.send_json(T_CLOSE, {"id": pid})
    c.close()
    dt = time.time() - t0
    return {"created": created, "seconds": dt,
            "panes_per_sec": created / dt if dt else 0}


def sc_attach_replay(sock, sink, n=30, log=print, live=False):
    """Replay cost: fill scrollback, then time re-attach snapshot delivery."""
    c = Client(sock)
    c.drain_welcome()
    ids = []
    rects = live_rects(n) if live else None
    for _ in range(n):
        rect = rects.pop(0) if rects else {"x": 0, "y": 0, "w": 100, "h": 100}
        c.send_json(T_CREATE, {"rect": rect,
                               "cwd": "/tmp",
                               "command": "/bin/bash --noprofile --norc -i"})
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        pid = json.loads(body)["meta"]["id"]
        ids.append(pid)
        sink.attach(pid)
    # 1MB of binary junk per pane through a real shell (bounded, exits fast).
    import uuid as uuidm
    for i, pid in enumerate(ids):
        c.send(T_INPUT, uuidm.UUID(pid).bytes +
               b"head -c 1000000 /dev/urandom; echo FILLDONE\n")
        if i % 10 == 0:
            log(f"  flood {i}/{n}")
    time.sleep(6)  # let the bursts land in the rings
    # Re-attach each pane on a fresh conn and time snapshot delivery.
    t0 = time.time()
    total = 0
    for pid in ids:
        a = Client(sock)
        a.drain_welcome()
        a.send_json(T_ATTACH, {"id": pid, "cols": 80, "rows": 24})
        # Snapshot is sent before any live bytes; first OUTPUT frame is it.
        try:
            tag, body = a.wait_for(lambda t, b: t == T_OUTPUT, timeout=60)
            total += len(body)
        except IOError as e:
            log(f"  reattach {pid[:8]} failed: {e}")
        a.close()
    dt = time.time() - t0
    for pid in ids:
        try:
            c.send_json(T_CLOSE, {"id": pid})
        except (OSError, IOError):
            break
    c.close()
    return {"panes": n, "reattach_seconds": dt,
            "reattach_per_sec": n / dt if dt else 0,
            "snapshot_bytes": total}


def sc_output_flood(sock, sink, panes=20, secs=15, mode="urandom", log=print,
                    live=False):
    """Sustained output: every pane spews as fast as the pty allows.

    The flood command IS the pane child (no shell round-trip): measures the
    daemon PTY read -> ring -> fanOut -> socket path at saturation.
    """
    # Direct argv spawn (no shell wrapper): matrix-tested, only direct exec
    # reliably emits on the pty — shell-wrapped children go silent.
    cmds = {
        "urandom": "cat /dev/urandom",
        "yes": "/usr/bin/yes OUTPUTFLOODLINE",
        "htop": "/opt/homebrew/bin/htop",
        "btop": "/opt/homebrew/bin/btop",
    }
    cmd = cmds[mode]
    c = Client(sock)
    c.drain_welcome()
    ids = []
    rects = live_rects(panes) if live else None
    for _ in range(panes):
        rect = rects.pop(0) if rects else {"x": 0, "y": 0, "w": 100, "h": 100}
        c.send_json(T_CREATE, {"rect": rect,
                               "cwd": "/tmp", "command": cmd})
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        pid = json.loads(body)["meta"]["id"]
        ids.append(pid)
        sink.attach(pid)
    log(f"  flooding {panes}x {mode} for {secs}s...")
    time.sleep(2)  # let children exec and reach steady state
    b0 = sink.bytes
    time.sleep(secs)
    mb = (sink.bytes - b0) / 1e6
    for pid in ids:
        try:
            c.send_json(T_CLOSE, {"id": pid})
        except (OSError, IOError):
            break
    c.close()
    return {"panes": panes, "mode": mode, "seconds": secs,
            "delivered_mb": mb, "delivered_mbps": mb / secs if secs else 0}


def sc_chaos_grid(sock, sink, grid=10, settle=5, chaos_secs=10,
                  log=print, live=False, fps_meter=None, rounds=3,
                  burst=200):
    """Live GUI burn-in: NxN grid of shelled panes, then ROUNDS of
    (burst of random move/focus ops, settle). FPS sampled per burst
    vs settled window — steady end-states, not in-flight thrash.

    Resize/focus go through the DAEMON protocol; the app applies them as
    real layout+camera work (movePane -> setRect, focus -> zoom/center) —
    same code path as keybinds. Requires live (the app must render).
    """
    import random
    if not live:
        return {"status": "SKIP", "reason": "chaos_grid needs --live"}
    n = grid * grid
    c = Client(sock)
    c.drain_welcome()
    # Realistic panes: true 80x30 terminals (Menlo 13pt ~ 7.8x15.5pt cells
    # + 22pt titlebar), 8px gutters. 10x10 = 6320x4950pt world; camera
    # fit-all handles the zoom, same as a real 100-pane session.
    pw, ph, gap = 624.0, 487.0, 8.0
    cols = grid
    ids = []
    for i in range(n):
        gx, gy = i % cols, i // cols
        # Real shells under mixed load (part of the test): workload picked
        # per-pane below — htop / btop / ticking counter / idle.
        c.send_json(T_CREATE, {
            "rect": {"x": float(gx * (pw + gap)), "y": float(gy * (ph + gap)),
                     "w": pw, "h": ph},
            "cwd": "/tmp",
            "command": "/bin/bash --noprofile --norc -i"})
        try:
            tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        except IOError as e:
            log(f"  grid create {i}/{n} failed: {e}; continuing with "
                f"{len(ids)}")
            break
        pid = json.loads(body)["meta"]["id"]
        ids.append(pid)
        sink.attach(pid)
        if (i + 1) % 50 == 0:
            log(f"  spawned {i + 1}/{n}")
    # Mixed load per pane (random): htop / btop / tick counter / idle shell.
    # Staggered to avoid a 100-way thundering herd on the daemon.
    import uuid as uuidm
    workloads = ["htop", "btop", "tick", "idle"]
    mix = {"htop": 0, "btop": 0, "tick": 0, "idle": 0}
    lrnd = random.Random(99)
    for j, pid in enumerate(ids):
        w = lrnd.choice(workloads)
        mix[w] += 1
        try:
            if w == "htop":
                c.send(T_INPUT, uuidm.UUID(pid).bytes + b"exec /opt/homebrew/bin/htop\n")
            elif w == "btop":
                c.send(T_INPUT, uuidm.UUID(pid).bytes + b"exec /opt/homebrew/bin/btop\n")
            elif w == "tick":
                c.send(T_INPUT, uuidm.UUID(pid).bytes +
                       b"i=0; while true; do echo tick-$((i+=1))-$(date +%S); "
                       b"sleep 0.2; done &\n")
            # idle: leave the bare shell alone.
        except (OSError, IOError):
            break
        if (j + 1) % 50 == 0:
            time.sleep(0.5)
    log(f"  workload mix: {mix}")
    m = fps_meter or FPSMeter()
    own_meter = fps_meter is None
    if own_meter:
        m.start()
    # move/focus ops, then waits `settle` seconds for layout + rendering to
    # quiesce. FPS is sampled separately for burst vs settled windows, so
    # the numbers reflect steady end-states, not in-flight thrash.
    edges = ["left", "right", "above", "below"]
    ops = {"grow": 0, "shrink": 0, "focus": 0}
    rnd = random.Random(1234)
    cur = {pid: {"x": float((i % cols) * (pw + gap)),
                 "y": float((i // cols) * (ph + gap)),
                 "w": pw, "h": ph}
           for i, pid in enumerate(ids)}
    round_stats = []
    for r in range(rounds):
        log(f"  round {r + 1}/{rounds}: {burst} ops burst...")
        tb0 = time.time()
        for _ in range(burst):
            pid = rnd.choice(ids)
            try:
                if rnd.random() < 0.4:
                    e = rnd.choice(edges)
                    grow = rnd.random() < 0.5
                    # Demo-visible strides: 10-25 CELLS per op.
                    cells = rnd.randint(10, 25)
                    dx, dy = 8.0 * cells, 16.0 * cells
                    d = 1.0 if grow else -1.0
                    rc = cur[pid]
                    if e == "right":
                        rc["w"] = max(200.0, rc["w"] + d * dx)
                    elif e == "left":
                        rc["x"] += d * dx if rc["w"] - d * dx >= 200 else 0
                        rc["w"] = max(200.0, rc["w"] - d * dx)
                    elif e == "above":
                        rc["h"] = max(160.0, rc["h"] + d * dy)
                    else:
                        rc["y"] += d * dy if rc["h"] - d * dy >= 160 else 0
                        rc["h"] = max(160.0, rc["h"] - d * dy)
                    c.send_json(T_MOVE, {"id": pid, "rect": dict(rc)})
                    ops["grow" if grow else "shrink"] += 1
                else:
                    tgt = rnd.choice(ids)
                    c.send_json(T_ATTACH, {"id": tgt, "cols": 80, "rows": 24})
                    ops["focus"] += 1
            except (OSError, IOError):
                break
        tb1 = time.time()
        fps_burst = m.fps_in(tb0, tb1)
        log(f"  round {r + 1}: burst done "
            f"({burst / max(0.01, tb1 - tb0):.0f} ops/s); "
            f"settling {settle}s...")
        ts0 = time.time()
        time.sleep(settle)
        ts1 = time.time()
        fps_settled = m.fps_in(ts0, ts1)
        # Settled-state audit: count overlapping pairs in the DAEMON store
        # (ground truth for layout). Screenshots catch transients; this
        # number must be zero every round.
        lan = Client(sock)
        lan.drain_welcome()
        rects = [(p["id"], p["rect"]) for p in lan.list_panes()]
        lan.close()
        def _ov(a, b):
            return (a["x"] < b["x"] + b["w"] and a["x"] + a["w"] > b["x"]
                    and a["y"] < b["y"] + b["h"] and a["y"] + a["h"] > b["y"])
        ovpairs = sum(1 for i in range(len(rects))
                      for j in range(i + 1, len(rects))
                      if _ov(rects[i][1], rects[j][1]))
        round_stats.append({
            "burst_ops": burst,
            "burst_secs": round(tb1 - tb0, 2),
            "fps_burst": round(fps_burst, 1),
            "fps_settled": round(fps_settled, 1),
            "overlap_pairs": ovpairs})
        log(f"  round {r + 1}: fps burst={fps_burst:.1f} "
            f"settled={fps_settled:.1f} overlap_pairs={ovpairs}")
    t1 = time.time()
    if own_meter:
        m.stop()
    for pid in ids:
        try:
            c.send_json(T_CLOSE, {"id": pid})
        except (OSError, IOError):
            break
    c.close()
    return {"grid": grid, "panes": len(ids), "rounds": rounds,
            "burst_ops": burst, "settle_secs": settle, "ops": ops,
            "round_stats": round_stats,
            "fps_burst_p50": round(sorted(
                r["fps_burst"] for r in round_stats)[len(round_stats) // 2], 1),
            "fps_settled_p50": round(sorted(
                r["fps_settled"] for r in round_stats)[len(round_stats) // 2], 1),
            "grab_rate": round(m.grab_rate, 1)}

def sc_resize_storm(sock, sink, panes=20, rounds=10, log=print, live=False):
    """Simultaneous resize: all panes reflowed at once, repeatedly."""
    c = Client(sock)
    c.drain_welcome()
    ids = []
    rects = live_rects(panes) if live else None
    for _ in range(panes):
        rect = rects.pop(0) if rects else {"x": 0, "y": 0, "w": 100, "h": 100}
        c.send_json(T_CREATE, {"rect": rect,
                               "cwd": "/tmp",
                               "command": "/usr/bin/top -l 99999 -s 1 -n 20"})
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        pid = json.loads(body)["meta"]["id"]
        ids.append(pid)
        sink.attach(pid)
    time.sleep(2)
    t0 = time.time()
    sizes = [(80, 24), (120, 40), (40, 10), (200, 60), (100, 30)]
    for r in range(rounds):
        for i, pid in enumerate(ids):
            cols, rows = sizes[(r + i) % len(sizes)]
            c.send_json(T_RESIZE, {"id": pid, "cols": cols, "rows": rows})
        time.sleep(0.3)
    dt = time.time() - t0
    for pid in ids:
        try:
            c.send_json(T_CLOSE, {"id": pid})
        except (OSError, IOError):
            break
    c.close()
    return {"panes": panes, "rounds": rounds,
            "resizes": panes * rounds, "seconds": dt,
            "resizes_per_sec": panes * rounds / dt if dt else 0}


def sc_move_storm(sock, sink, panes=30, rounds=20, log=print, live=False):
    """Move/persist storm: worst case for the debounced state saver."""
    c = Client(sock)
    c.drain_welcome()
    ids = []
    rects = live_rects(panes) if live else None
    for _ in range(panes):
        rect = rects.pop(0) if rects else {"x": 0, "y": 0, "w": 100, "h": 100}
        c.send_json(T_CREATE, {"rect": rect,
                               "cwd": "/tmp", "command": "/bin/sleep 60"})
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        ids.append(json.loads(body)["meta"]["id"])
    t0 = time.time()
    n = 0
    for r in range(rounds):
        for i, pid in enumerate(ids):
            c.send_json(T_MOVE, {"id": pid, "rect": {
                "x": float((r * 37 + i * 53) % 5000),
                "y": float((r * 91 + i * 17) % 5000),
                "w": 100.0, "h": 100.0}})
            n += 1
    dt = time.time() - t0
    time.sleep(1.5)  # let the debounced save flush
    st = os.path.join(os.path.dirname(sock), "state.json")
    st_size = os.path.getsize(st) if os.path.exists(st) else -1
    for pid in ids:
        try:
            c.send_json(T_CLOSE, {"id": pid})
        except (OSError, IOError):
            break
    c.close()
    return {"panes": panes, "moves": n, "seconds": dt,
            "moves_per_sec": n / dt if dt else 0, "state_bytes": st_size}


def sc_many_idle(sock, sink, n=150, log=print, live=False):
    """Idle footprint: n live shells, sampling steady-state RSS/fds."""
    c = Client(sock)
    c.drain_welcome()
    ids = []
    rects = live_rects(n) if live else None
    for i in range(n):
        rect = rects[i] if rects else {"x": 0, "y": 0, "w": 100, "h": 100}
        c.send_json(T_CREATE, {"rect": rect,
                               "cwd": "/tmp", "command": "/bin/sleep 300"})
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        pid = json.loads(body)["meta"]["id"]
        ids.append(pid)
        sink.attach(pid)
        if (i + 1) % 50 == 0:
            log(f"  spawned {i + 1}/{n}")
    log(f"  {n} idle panes live; settling 5s...")
    time.sleep(5)
    for pid in ids:
        try:
            c.send_json(T_CLOSE, {"id": pid})
        except (OSError, IOError):
            break  # backpressure: daemon stopped reading; leak check below
    c.close()
    # reap check: daemon should drop back near zero panes
    time.sleep(2)
    q = Client(sock)
    q.drain_welcome()
    try:
        left = len(q.list_panes(timeout=15))
    except IOError:
        left = -1  # control plane wedged or daemon dead
    q.close()
    return {"panes": n, "leaked_panes": left}


def sc_exit_reap(sock, sink, n=100, log=print, live=False):
    """Exit/reaper path: panes whose children die on their own."""
    c = Client(sock)
    c.drain_welcome()
    ids = []
    rects = live_rects(n) if live else None
    for _ in range(n):
        rect = rects.pop(0) if rects else {"x": 0, "y": 0, "w": 100, "h": 100}
        c.send_json(T_CREATE, {"rect": rect,
                               "cwd": "/tmp", "command": "/bin/sleep 1"})
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        ids.append(json.loads(body)["meta"]["id"])
    log(f"  {n} short-lived panes spawned; waiting for reaper...")
    time.sleep(6)
    q = Client(sock)
    q.drain_welcome()
    try:
        left = len(q.list_panes(timeout=15))
    except IOError:
        left = -1  # control plane wedged or daemon dead
    q.close()
    c.close()
    return {"panes": n, "leaked_panes": left}


def sc_slow_subscriber(sock, sink, panes=5, secs=20, log=print, live=False):
    """Backpressure boundary: a subscriber that attaches and never reads.

    The daemon fans out with blocking writes under the server lock, so one
    stalled client is expected to stall every pane today. Pass = control
    plane stays responsive for the whole window. Run alone (own suite):
    a wedge here can poison later scenarios on the same daemon.
    """
    c = Client(sock)
    c.drain_welcome()
    ids = []
    for _ in range(panes):
        c.send_json(T_CREATE, {"rect": {"x": 0, "y": 0, "w": 100, "h": 100},
                               "cwd": "/tmp",
                               "command": "/usr/bin/yes BLACKHOLE"})
        tag, body = c.wait_for(lambda t, b: t == T_CREATED, timeout=30)
        ids.append(json.loads(body)["meta"]["id"])
    holes = []
    for pid in ids:
        h = Client(sock)  # drains welcome, attaches, THEN goes black-hole
        h.drain_welcome()
        h.send_json(T_ATTACH, {"id": pid, "cols": 80, "rows": 24})
        try:
            h.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        except OSError:
            pass
        h.closed = True  # stop the reader: socket buffer fills, never drains
        holes.append(h)
    t0 = time.time()
    probes = []
    responsive = True
    while time.time() - t0 < secs:
        time.sleep(2)
        try:
            q = Client(sock)
            q.drain_welcome(timeout=5)
            probes.append(len(q.list_panes(timeout=5)))
            q.close()
        except Exception as e:
            probes.append(f"FAIL:{type(e).__name__}")
            responsive = False
            break
    for h in holes:
        h.close()
    for pid in ids:
        try:
            c.send_json(T_CLOSE, {"id": pid})
        except (OSError, IOError):
            break
    c.close()
    return {"panes": panes, "seconds": secs,
            "control_responsive": responsive, "probes": probes}

SCENARIOS = {
    "create_close_storm": sc_create_close_storm,
    "attach_replay": sc_attach_replay,
    "output_flood_urandom": lambda s, k, **kw: sc_output_flood(s, k, mode="urandom", **kw),
    "output_flood_yes": lambda s, k, **kw: sc_output_flood(s, k, mode="yes", **kw),
    "output_flood_htop": lambda s, k, **kw: sc_output_flood(s, k, mode="htop", **kw),
    "resize_storm": sc_resize_storm,
    "move_storm": sc_move_storm,
    "many_idle": sc_many_idle,
    "exit_reap": sc_exit_reap,
    "slow_subscriber": sc_slow_subscriber,
    "chaos_grid": sc_chaos_grid,
}

SUITES = {
    "smoke": [("create_close_storm", {"n": 20, "batch": 10}),
              ("many_idle", {"n": 20}),
              ("exit_reap", {"n": 10})],
    "standard": [("create_close_storm", {"n": 200, "batch": 20}),
                 ("many_idle", {"n": 150}),
                 ("output_flood_yes", {"panes": 10, "secs": 10}),
                 ("output_flood_htop", {"panes": 10, "secs": 10}),
                 ("resize_storm", {"panes": 20, "rounds": 10}),
                 ("move_storm", {"panes": 30, "rounds": 20}),
                 ("attach_replay", {"n": 30}),
                 ("exit_reap", {"n": 100})],
    "brutal": [("create_close_storm", {"n": 500, "batch": 50}),
               ("many_idle", {"n": 300}),
               ("output_flood_urandom", {"panes": 20, "secs": 15}),
               ("output_flood_yes", {"panes": 30, "secs": 15}),
               ("output_flood_htop", {"panes": 20, "secs": 15}),
               ("resize_storm", {"panes": 50, "rounds": 20}),
               ("move_storm", {"panes": 100, "rounds": 30}),
               ("attach_replay", {"n": 50}),
               ("exit_reap", {"n": 200})],
    "backpressure": [("slow_subscriber", {"panes": 5, "secs": 20})],
    "chaos": [("chaos_grid", {"grid": CHAOS_DEFAULT_GRID, "settle": 10,
                              "rounds": 3, "burst": 200})],
}


# ---------------------------------------------------------------- runner

def live_daemon_pid(sock):
    """Resolve the daemon behind a live socket via its pid file sidecar."""
    support = os.path.dirname(sock)
    for cand in (os.path.join(support, "daemon.pid"),):
        try:
            with open(cand) as f:
                pid = int(f.read().strip())
            import psutil
            psutil.Process(pid)  # raises when stale
            return pid
        except (OSError, ValueError):
            continue
        except Exception:
            return None
    return None


def rep_stats(vals):
    """p50/p95/max/min/mean over repeat iterations (empty -> {})."""
    if not vals:
        return {}
    vs = sorted(vals)
    return {"n": len(vs), "min": vs[0], "p50": vs[len(vs) // 2],
            "p95": vs[int(len(vs) * 0.95)], "max": vs[-1],
            "mean": sum(vs) / len(vs)}


def run_live(suite, gpu=False, repeat=1):
    """Drive the RUNNING session: panes render on the canvas (GPU path)."""
    import psutil  # noqa
    sock = LIVE_SOCK
    if not os.path.exists(sock):
        sys.exit(f"no live daemon at {sock}: launch the app first")
    dp = live_daemon_pid(sock)
    if dp is None:
        sys.exit("live daemon pid unknown (stale/missing daemon.pid)")
    app_pid = find_app_pid()
    print(f"[bench] LIVE on {sock} (daemon={dp} app={app_pid}); "
          f"windows WILL open/close on your canvas")
    try:
        input("[bench] ENTER to thrash your canvas, Ctrl-C to abort: ")
    except (EOFError, KeyboardInterrupt):
        print("\naborted")
        return {"suite": suite, "mode": "live-aborted"}
    sink = Sink(sock)
    sink.start()
    sampler = Sampler(dp, interval=0.25, app_pid=app_pid, gpu=gpu)
    sampler.start()
    fps = FPSMeter()
    fps.start()
    report = {"suite": suite, "mode": "live",
              "started": datetime.now(timezone.utc).isoformat(),
              "scenarios": {}}
    failures = 0
    pre = set()
    try:
        pre = {p["id"] for p in Client(sock).list_panes()}
    except Exception:
        pass
    try:
        for name, kw in SUITES[suite]:
            kw = dict(kw)
            # Live caps: the app renders every pane; don't OOM the canvas.
            for k in ("n", "panes"):
                if k in kw and kw[k] > LIVE_PANE_CAP:
                    print(f"[bench] live cap: {name}.{k} {kw[k]} -> "
                          f"{LIVE_PANE_CAP}")
                    kw[k] = LIVE_PANE_CAP
            if name == "create_close_storm":
                kw["batch"] = min(kw.get("batch", 10), 10)
            iters = []
            res = None
            for it in range(repeat):
                print(f"[bench] === LIVE {name} {kw} "
                      f"(iter {it + 1}/{repeat}) ===")
                fn = SCENARIOS[name]
                t0 = time.time()
                try:
                    res = fn(sock, sink,
                             log=lambda m: print(f"[bench] {name}: {m}"),
                             live=True, fps_meter=fps, **kw) \
                        if name == "chaos_grid" else fn(
                            sock, sink,
                            log=lambda m: print(f"[bench] {name}: {m}"),
                            live=True, **kw)
                    res["status"] = "ok"
                except Exception as e:
                    import traceback
                    traceback.print_exc()
                    res = {"status": "FAIL",
                           "error": f"{type(e).__name__}: {e}"}
                    failures += 1
                res["wall_seconds"] = time.time() - t0
                res["iter"] = it + 1
                iters.append(res)
                time.sleep(2)
            # Aggregate: last iter's full dict + rep_stats over the
            # throughput-ish numeric keys across iters.
            res = dict(iters[-1])
            agg = {}
            keys = set()
            for r in iters:
                keys.update(k for k, v in r.items()
                            if isinstance(v, (int, float)) and k != "iter")
            for k in sorted(keys):
                agg[k] = rep_stats([r[k] for r in iters
                                    if isinstance(r.get(k), (int, float))])
            res["repeats"] = {"n": repeat, "metrics": agg,
                              "wall_seconds": rep_stats(
                                  [r["wall_seconds"] for r in iters])}
            res["resources"] = summarize(sampler.series)
            report["scenarios"][name] = res
            print(f"[bench] {name} x{repeat}: {json.dumps(res['repeats'])}")
            time.sleep(2)
            try:
                psutil.Process(dp)
            except psutil.NoSuchProcess:
                print("[bench] LIVE DAEMON DIED — aborting")
                report["daemon_died_at"] = name
                break
    finally:
        # Leave the user's canvas as found: close anything we created.
        try:
            left = Client(sock).list_panes()
            mine = [p["id"] for p in left if p["id"] not in pre]
            if mine:
                print(f"[bench] closing {len(mine)} leftover bench panes...")
                c = Client(sock)
                c.drain_welcome()
                for pid in mine:
                    try:
                        c.send_json(T_CLOSE, {"id": pid})
                    except (OSError, IOError):
                        break
                c.close()
        except Exception as e:
            print(f"[bench] cleanup failed: {e}")
        sink.stop()
        sampler.stop_ev.set()
        fps.stop()
        time.sleep(0.5)
        report["fps_grab_rate"] = round(fps.grab_rate, 1)
        # app-side rollup: p50/max RSS+CPU of the RENDERING process
        apps = [s["app"] for s in sampler.series if "app" in s]
        if apps:
            report["app_total"] = {
                "rss_mb": {"p50": sorted(a["rss_mb"] for a in apps)[len(apps)//2],
                           "max": max(a["rss_mb"] for a in apps)},
                "cpu_pct": {"p50": sorted(a["cpu_pct"] for a in apps)[len(apps)//2],
                            "max": max(a["cpu_pct"] for a in apps)},
                "samples": len(apps)}
        report["sink"] = {"mb": sink.bytes / 1e6, "frames": sink.frames}
        report["finished"] = datetime.now(timezone.utc).isoformat()
        report["failures"] = failures
    return report


def run_suite(suite, workdir=None, keep=False, repeat=1):
    try:
        import psutil  # noqa
    except ImportError:
        sys.exit("need psutil: pip install psutil")
    for f in (GCTD, PTYEXEC):
        if not os.path.exists(f):
            sys.exit(f"missing {f}: build with scripts/build.sh first")
    own_dir = workdir is None
    if own_dir:
        workdir = tempfile.mkdtemp(prefix="gctbench-")
    else:
        os.makedirs(workdir, exist_ok=True)
    print(f"[bench] workdir {workdir}")
    daemon, env = spawn_daemon(workdir)
    sock = env["GCT_SOCK"]
    sink = Sink(sock)
    sink.start()
    sampler = Sampler(daemon, interval=0.25)
    sampler.start()
    report = {"suite": suite, "started": datetime.now(timezone.utc).isoformat(),
              "scenarios": {}}
    failures = 0
    try:
        for name, kw in SUITES[suite]:
            iters = []
            res = None
            for it in range(repeat):
                print(f"[bench] === {name} {kw} (iter {it + 1}/{repeat}) ===")
                fn = SCENARIOS[name]
                t0 = time.time()
                try:
                    res = fn(sock, sink,
                             log=lambda m: print(f"[bench] {name}: {m}"), **kw)
                    res["status"] = "ok"
                except Exception as e:
                    import traceback
                    traceback.print_exc()
                    res = {"status": "FAIL",
                           "error": f"{type(e).__name__}: {e}"}
                    failures += 1
                    try:
                        res["daemon_alive"] = sample(daemon)[0].get("alive")
                        tail = subprocess.run(
                            ["tail", "-25",
                             os.path.join(workdir, "daemon.log")],
                            capture_output=True, text=True,
                            timeout=5).stdout
                        res["daemon_log_tail"] = tail[-2000:]
                    except Exception:
                        pass
                res["wall_seconds"] = time.time() - t0
                res["iter"] = it + 1
                iters.append(res)
                # settle + leak check between iterations
                time.sleep(2)
                if not sample(daemon)[0].get("alive"):
                    print("[bench] DAEMON DIED — aborting suite")
                    report["daemon_died_at"] = name
                    break
            res = dict(iters[-1])
            agg = {}
            keys = set()
            for r in iters:
                keys.update(k for k, v in r.items()
                            if isinstance(v, (int, float)) and k != "iter")
            for k in sorted(keys):
                agg[k] = rep_stats([r[k] for r in iters
                                    if isinstance(r.get(k), (int, float))])
            res["repeats"] = {"n": repeat, "metrics": agg,
                              "wall_seconds": rep_stats(
                                  [r["wall_seconds"] for r in iters])}
            # per-scenario resource peak since suite start
            res["resources"] = summarize(sampler.series)
            report["scenarios"][name] = res
            print(f"[bench] {name} x{repeat}: {json.dumps(res['repeats'])}")
            # settle + leak check between scenarios
            time.sleep(2)
            if not sample(daemon)[0].get("alive"):
                print("[bench] DAEMON DIED — aborting suite")
                report["daemon_died_at"] = name
                break
    finally:
        sink.stop()
        sampler.stop_ev.set()
        time.sleep(0.5)
        report["total"] = summarize(sampler.series)
        report["sink"] = {"mb": sink.bytes / 1e6, "frames": sink.frames}
        report["finished"] = datetime.now(timezone.utc).isoformat()
        report["failures"] = failures
        try:
            daemon.terminate()
            daemon.wait(timeout=5)
        except Exception:
            daemon.kill()
        if own_dir and not keep:
            shutil.rmtree(workdir, ignore_errors=True)
    return report


def main():
    ap = argparse.ArgumentParser(description="GCT brutal benchmark suite")
    ap.add_argument("--suite", default="smoke",
                    choices=list(SUITES) + ["all"])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--workdir", default=None)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--set-baseline", action="store_true",
                    help="store this report as bench/baseline.json")
    ap.add_argument("--live", action="store_true",
                    help="drive the RUNNING session (windows open on your "
                         "canvas; renders through Metal = GPU test)")
    ap.add_argument("--gpu", action="store_true",
                    help="sample GPU counters too (best-effort, no sudo needed "
                         "for ioreg path)")
    ap.add_argument("--yes", action="store_true",
                    help="skip the live-mode confirmation prompt")
    ap.add_argument("--repeat", type=int, default=1,
                    help="iterations per scenario (default 1); report keeps "
                         "p50/p95/max/min/mean across iters")
    ap.add_argument("--grid", type=int, default=None,
                    help="chaos grid width (default 10 → 10x10=100 panes; "
                         "50 → 50x50=2500 panes, live only)")
    args = ap.parse_args()
    if args.list:
        for s, steps in SUITES.items():
            print(f"{s}:")
            for name, kw in steps:
                print(f"  {name} {kw}")
        return
    suites = list(SUITES) if args.suite == "all" else [args.suite]
    os.makedirs(os.path.join(REPO, "bench", "results"), exist_ok=True)
    for suite in suites:
        if args.grid is not None and suite == "chaos":
            SUITES["chaos"] = [("chaos_grid", {"grid": args.grid, "settle": 10,
                                               "rounds": 3, "burst": 200})]
            print(f"[bench] chaos grid override: {args.grid}x{args.grid} = "
                  f"{args.grid * args.grid} panes")
        if args.live:
            if args.yes:
                import builtins
                builtins.input = lambda *a, **k: ""
            report = run_live(suite, gpu=args.gpu, repeat=args.repeat)
            tag = "live"
        else:
            report = run_suite(suite, workdir=args.workdir, keep=args.keep,
                               repeat=args.repeat)
            tag = "iso"
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        path = os.path.join(REPO, "bench", "results", f"{ts}_{suite}_{tag}.json")
        with open(path, "w") as f:
            json.dump(report, f, indent=1)
        print(f"[bench] report: {path}")
        base = os.path.join(REPO, "bench", "baseline.json")
        if args.set_baseline:
            shutil.copy(path, base)
            print(f"[bench] baseline set: {base}")
        elif os.path.exists(base):
            with open(base) as f:
                old = json.load(f)
            print(compare(old, report))


def compare(old, new):
    lines = ["[bench] vs baseline:"]
    ot, nt = old.get("total", {}), new.get("total", {})
    for k in ("rss_mb", "cpu_pct", "fds", "threads"):
        o, n = (ot.get(k) or {}).get("max"), (nt.get(k) or {}).get("max")
        if o is None or n is None:
            continue
        d = (n - o) / o * 100 if o else 0
        lines.append(f"  total.{k}.max: {o:.1f} -> {n:.1f} ({d:+.0f}%)")
    for name, nr in new.get("scenarios", {}).items():
        o = (old.get("scenarios") or {}).get(name, {})
        for k in ("panes_per_sec", "moves_per_sec", "resizes_per_sec",
                  "reattach_per_sec", "delivered_mbps"):
            if k in nr and k in o and o[k]:
                d = (nr[k] - o[k]) / o[k] * 100
                lines.append(f"  {name}.{k}: {o[k]:.1f} -> {nr[k]:.1f} ({d:+.0f}%)")
    return "\n".join(lines)


if __name__ == "__main__":
    main()
