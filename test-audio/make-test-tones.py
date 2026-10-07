#!/usr/bin/env python3
"""Regenerate the stereo test files (needs ffmpeg with libvorbis).

lr-tones.ogg: 2 s each of left only (440 Hz), right only (660 Hz), both (550 Hz); 4 loops, 24 s.
lr-1khz.ogg:  the same 1 kHz tone left only, right only, both, 2 s each with 50 ms fades and 250 ms gaps; 4 loops.
"""
import math, os, struct, subprocess, wave

R = 48000
os.chdir(os.path.dirname(os.path.abspath(__file__)))  # write next to this script

def tones():
    out = bytearray()
    for _ in range(4):
        for mode, f in (("L", 440), ("R", 660), ("B", 550)):
            for i in range(R * 2):
                a = int(9000 * math.sin(2 * math.pi * f * i / R))
                out += struct.pack("<hh", a if mode in "LB" else 0, a if mode in "RB" else 0)
    return out

def one_khz():
    out = bytearray()
    for _ in range(4):
        for mode in "LRB":
            for i in range(R * 2):
                env = min(1, i / 2400, (R * 2 - i) / 2400)
                a = int(9000 * env * math.sin(2 * math.pi * 1000 * i / R))
                out += struct.pack("<hh", a if mode in "LB" else 0, a if mode in "RB" else 0)
            out += b"\0" * 4 * (R // 4)
    return out

for name, pcm in (("lr-tones", tones()), ("lr-1khz", one_khz())):
    with wave.open(name + ".wav", "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(R); w.writeframes(bytes(pcm))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", name + ".wav", "-c:a", "libvorbis", "-q:a", "3", name + ".ogg"], check=True)
    os.remove(name + ".wav")
    print("wrote", name + ".ogg")
