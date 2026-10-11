"""Sound design for the reel, synthesized (no sample libraries):

    python3 demo/edit/sfx.py           -> ~/Movies/GCT Reel/work/sfx/<name>.wav

    hit      sub boom (70 -> 32 Hz drop) + transient click     cuts, cards
    boom     hit with a long dark tail                         last card
    whoosh   noise pass-by, band sweeps up then down, L -> R   fast moves
    riser    1.9s noise + tone climbing into a cut             pre-drop
    spool    turbine spool-up: rising harmonics + whine        cold open
    lock     mechanical ka-chunk (click, then thump)           panes snap
    tick     short UI blip                                     type decode
    servo    whine glide with vibrato                          camera moves

48 kHz stereo, float math, peaks normalized to -1 dBFS. edit/cut.py mixes
them per shot ("sfx": [[name, offset_s, gain_db], ...]).
"""

from __future__ import annotations

import pathlib
import wave

import numpy as np

OUT = pathlib.Path.home() / "Movies/GCT Reel/work/sfx"
SR = 48000
PEAK = 10 ** (-1 / 20)            # -1 dBFS
RNG = np.random.default_rng(7)    # same sounds every run


def t_axis(seconds: float) -> np.ndarray:
    return np.arange(int(seconds * SR)) / SR


def sweep(f0: float, f1: float, seconds: float, curve: float = 1.0) -> np.ndarray:
    # Sine whose frequency glides f0 -> f1 (curve > 1 = slow start).
    t = t_axis(seconds)
    f = f0 + (f1 - f0) * (t / seconds) ** curve
    return np.sin(2 * np.pi * np.cumsum(f) / SR)


def lowpass(x: np.ndarray, cutoff, poles: int = 3) -> np.ndarray:
    # Cascaded one-pole lowpass (18 dB/oct at 3 poles; one pole leaves
    # whooshes as white hiss). cutoff may be per-sample (moving filter).
    c = np.broadcast_to(np.asarray(cutoff, float), x.shape)
    a = np.exp(-2 * np.pi * c / SR)
    y = x
    for _ in range(poles):
        out = np.empty_like(y)
        acc = 0.0
        for i in range(len(y)):
            acc = (1 - a[i]) * y[i] + a[i] * acc
            out[i] = acc
        y = out
    return y


def bandpass(x: np.ndarray, lo, hi) -> np.ndarray:
    return lowpass(x, hi) - lowpass(x, lo)


def resonate(x: np.ndarray, freq: float, decay: float) -> np.ndarray:
    # Ringing body (metal): impulse response of a damped sine, via FFT.
    t = t_axis(decay * 6)
    ir = np.sin(2 * np.pi * freq * t) * np.exp(-t / decay)
    return fftconv(x, ir)[: len(x)]


def fftconv(x: np.ndarray, ir: np.ndarray) -> np.ndarray:
    n = len(x) + len(ir) - 1
    size = 1 << (n - 1).bit_length()
    return np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[:n]


def room(x: np.ndarray, seconds: float, darkness: float = 2500) -> np.ndarray:
    # Hangar tail: decaying, darkened noise as an impulse response.
    t = t_axis(seconds)
    ir = lowpass(RNG.standard_normal(len(t)) * np.exp(-t / (seconds / 5)), darkness)
    wet = fftconv(x, ir / np.abs(ir).sum() * 40)
    dry = np.pad(x, (0, len(wet) - len(x)))
    return dry + 0.35 * wet


def env(seconds: float, attack: float, release: float) -> np.ndarray:
    t = t_axis(seconds)
    return np.minimum(1, t / max(attack, 1e-4)) * np.exp(-t / release)


def stereo(x: np.ndarray, pan=0.0) -> np.ndarray:
    # pan: -1 left .. 1 right, scalar or per-sample (equal power).
    p = (np.broadcast_to(np.asarray(pan, float), x.shape) + 1) * np.pi / 4
    return np.stack([x * np.cos(p), x * np.sin(p)], axis=1)


# --- Sounds --------------------------------------------------------------------
def hit() -> np.ndarray:
    sub = sweep(70, 32, 1.8, curve=0.35) * env(1.8, 0.004, 0.55)
    click = lowpass(RNG.standard_normal(int(0.02 * SR)), 3000) * np.linspace(1, 0, int(0.02 * SR))
    body = np.tanh(2.2 * sub)              # a little saturation = weight
    body[: len(click)] += 0.6 * click
    return stereo(body)


def boom() -> np.ndarray:
    return stereo(room(hit()[:, 0], 3.5, darkness=900))


def whoosh() -> np.ndarray:
    dur = 1.1
    t = t_axis(dur)
    shape = np.sin(np.pi * t / dur) ** 2
    cutoff = 300 + 5200 * shape
    x = bandpass(RNG.standard_normal(len(t)), cutoff * 0.25, cutoff) * shape
    return stereo(x, pan=np.linspace(-0.8, 0.8, len(t)))


def riser() -> np.ndarray:
    dur = 1.9
    t = t_axis(dur)
    ramp = (t / dur) ** 2.2
    noise = bandpass(RNG.standard_normal(len(t)), 200 + 3000 * ramp, 800 + 9000 * ramp) * ramp
    tone = sweep(110, 880, dur, curve=2.0) * ramp * 0.25
    return stereo(noise + tone)


def spool() -> np.ndarray:
    # Jet start: fundamental climbs, harmonics + compressor whine follow.
    dur = 3.4
    t = t_axis(dur)
    ramp = (t / dur) ** 1.6
    f = 60 + 520 * ramp + 6 * np.sin(2 * np.pi * 7 * t)
    phase = 2 * np.pi * np.cumsum(f) / SR
    tone = sum(np.sin(k * phase) / k for k in range(1, 7))
    whine = np.sin(9 * phase) * 0.15 * ramp
    air = lowpass(RNG.standard_normal(len(t)), 400 + 6000 * ramp) * 0.8
    return stereo((0.5 * tone + whine + air) * np.minimum(1, ramp * 3))


def lock() -> np.ndarray:
    dur = 0.45
    click = np.zeros(int(dur * SR))
    burst = RNG.standard_normal(int(0.006 * SR))
    click[: len(burst)] = burst
    metal = resonate(click, 2400, 0.02) + 0.6 * resonate(click, 4100, 0.012)
    thump = np.zeros_like(click)
    k = int(0.028 * SR)
    th = sweep(120, 55, dur - 0.028, curve=0.5) * env(dur - 0.028, 0.002, 0.07)
    thump[k:] = th[: len(thump) - k]
    return stereo(0.5 * metal / np.abs(metal).max() + np.tanh(2 * thump))


def tick() -> np.ndarray:
    blip = np.sin(2 * np.pi * 1600 * t_axis(0.03)) * env(0.03, 0.001, 0.008)
    return stereo(blip)


def servo() -> np.ndarray:
    dur = 0.5
    t = t_axis(dur)
    f = 380 + 900 * (t / dur) ** 0.7 + 18 * np.sin(2 * np.pi * 23 * t)
    tone = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.3 * np.sin(4 * np.pi * np.cumsum(f) / SR)
    shape = np.sin(np.pi * t / dur) ** 0.6
    return stereo(tone * shape * 0.6 + bandpass(RNG.standard_normal(len(t)), 600, 3000) * shape * 0.2)


SOUNDS = {f.__name__: f for f in (hit, boom, whoosh, riser, spool, lock, tick, servo)}


def write(path: pathlib.Path, x: np.ndarray) -> None:
    x = x / np.abs(x).max() * PEAK
    pcm = (x * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, make in SOUNDS.items():
        write(OUT / f"{name}.wav", make())
        print(OUT / f"{name}.wav")


if __name__ == "__main__":
    main()
