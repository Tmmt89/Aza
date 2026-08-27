#!/usr/bin/env python3
"""Синтезирует короткие сигналы уведомления для Aza.

Звуки сгенерированы, а не взяты откуда-то: никаких лицензий и вопросов о
происхождении. Синтез аддитивный — сумма затухающих синусоид, как звучит
ударенный металл или дерево.
"""
import math
import struct
import wave

RATE = 44100


def render(partials, seconds, attack=0.004):
    """partials: [(частота, громкость, время затухания)]."""
    total = int(RATE * seconds)
    samples = [0.0] * total
    for freq, gain, decay in partials:
        w = 2 * math.pi * freq
        for i in range(total):
            t = i / RATE
            samples[i] += gain * math.sin(w * t) * math.exp(-t / decay)
    # Мягкая атака: щелчок в начале — самое неприятное, что бывает
    # у коротких сигналов.
    rise = max(1, int(RATE * attack))
    for i in range(rise):
        samples[i] *= i / rise
    # Затухание в самом конце, чтобы файл не обрывался ступенькой.
    tail = int(RATE * 0.02)
    for i in range(tail):
        samples[total - tail + i] *= 1 - i / tail
    peak = max(abs(s) for s in samples) or 1.0
    return [s / peak * 0.72 for s in samples]


def write(path, samples):
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))


def mix(first, second, offset):
    """Две ноты подряд с наложением хвоста первой на вторую."""
    shift = int(RATE * offset)
    total = max(len(first), shift + len(second))
    out = [0.0] * total
    for i, s in enumerate(first):
        out[i] += s
    for i, s in enumerate(second):
        out[shift + i] += s * 0.9
    peak = max(abs(s) for s in out) or 1.0
    return [s / peak * 0.72 for s in out]


# Колокольчик: негармонические обертоны — так звучит металл.
chime = render([(880, 1.0, 0.9), (1320, 0.5, 0.7),
                (2093, 0.28, 0.45), (2637, 0.14, 0.3)], 1.6)
write("chime.wav", chime)

# Две ноты: ля и ми выше — чистая квинта, спокойный интервал.
low = render([(660, 1.0, 0.55), (1320, 0.3, 0.35)], 0.9)
high = render([(988, 1.0, 0.7), (1976, 0.28, 0.4)], 1.1)
write("twotone.wav", mix(low, high, 0.22))

# Тёплый тон: мало обертонов, быстрое затухание — ближе к маримбе.
warm = render([(523, 1.0, 0.5), (1046, 0.22, 0.25), (1568, 0.08, 0.15)], 1.0)
write("warm.wav", warm)

for name, data in (("chime", chime), ("twotone", mix(low, high, 0.22)), ("warm", warm)):
    print(f"{name}: {len(data)/RATE:.2f} с, пик {max(abs(s) for s in data):.2f}")
