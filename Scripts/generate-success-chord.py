#!/usr/bin/env python3
"""Generate Eject Different's original success chord (CC0)."""
import math, struct, wave
from pathlib import Path

rate = 48000
duration = 1.45
# Bright C-major add-9: familiar optimism, original synthesis—not an Apple recording.
notes = [(261.63, .30), (329.63, .24), (392.00, .25), (523.25, .16), (587.33, .10)]
out = Path(__file__).resolve().parents[1] / "Sources" / "EjectDifferent" / "Resources" / "different.wav"
out.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(out), "wb") as w:
    w.setparams((2, 2, rate, 0, "NONE", "not compressed"))
    frames = bytearray()
    for i in range(int(rate * duration)):
        t = i / rate
        attack = min(1.0, t / 0.018)
        release = math.exp(-3.1 * t)
        sample = sum(a * math.sin(2 * math.pi * f * t) for f, a in notes)
        sample += .06 * math.sin(2 * math.pi * 1046.5 * t) * math.exp(-7 * t)
        v = max(-1.0, min(1.0, sample * attack * release))
        left = int(v * 27500)
        right = int(v * 27200)
        frames += struct.pack("<hh", left, right)
    w.writeframes(frames)
print(out)
