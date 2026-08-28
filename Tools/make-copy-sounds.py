#!/usr/bin/env python3
"""Синтезирует короткие звуки копирования для Aza.

Системные Tink/Pop/Purr резкие и громкие — свои звуки тише (пик 0.5),
короче и с мягкой атакой. Синтез тот же, что в make-notification-tones.py:
сумма затухающих синусоид, плюс глиссандо для «капли».

Запуск из корня репозитория:
    python3 Tools/make-copy-sounds.py
    for f in copy-*.wav; do afconvert -f caff -d LEI16 "$f" \
        "Aza/Resources/${f%.wav}.caf" && rm "$f"; done
"""
import math
import struct
import wave

RATE = 44100
PEAK = 0.5  # звук-подтверждение должен быть тихим


def envelope(samples, attack=0.003):
    """Мягкая атака и хвост: щелчки по краям — самое неприятное."""
    rise = max(1, int(RATE * attack))
    for i in range(rise):
        samples[i] *= i / rise
    tail = int(RATE * 0.02)
    total = len(samples)
    for i in range(tail):
        samples[total - tail + i] *= 1 - i / tail
    peak = max(abs(s) for s in samples) or 1.0
    return [s / peak * PEAK for s in samples]


def render(partials, seconds, attack=0.003):
    """partials: [(частота, громкость, время затухания)]."""
    total = int(RATE * seconds)
    samples = [0.0] * total
    for freq, gain, decay in partials:
        w = 2 * math.pi * freq
        for i in range(total):
            t = i / RATE
            samples[i] += gain * math.sin(w * t) * math.exp(-t / decay)
    return envelope(samples, attack)


def glide(f0, f1, seconds, decay, attack=0.003):
    """Экспоненциальное глиссандо: вниз — мягкий «поп», вверх — «булька»."""
    total = int(RATE * seconds)
    samples = [0.0] * total
    phase = 0.0
    for i in range(total):
        t = i / RATE
        freq = f0 * (f1 / f0) ** (t / seconds)
        phase += 2 * math.pi * freq / RATE
        samples[i] = math.sin(phase) * math.exp(-t / decay)
    return envelope(samples, attack)


def mix(first, second, offset):
    """Две ноты подряд с наложением хвоста первой на вторую."""
    shift = int(RATE * offset)
    total = max(len(first), shift + len(second))
    out = [0.0] * total
    for i, s in enumerate(first):
        out[i] += s
    for i, s in enumerate(second):
        out[shift + i] += s * 0.9
    return envelope(out)


# Тик: сухой деревянный щелчок, как клавиша хорошей клавиатуры.
tick = render([(1760, 1.0, 0.045), (2637, 0.35, 0.03), (3520, 0.12, 0.02)], 0.22)

# Бум: низкий войлочный удар, как приглушённая клавиша пианино.
# Хлопки-глиссандо (звался «Поп») не зашли ни в одном варианте.
# Ниже 165 Гц нельзя: динамики ноутбука такое уже не воспроизводят,
# слышимость держит вторая гармоника.
pop = render([(165, 1.0, 0.11), (330, 0.35, 0.06), (495, 0.1, 0.03)],
             0.28, attack=0.015)

# Динь: две быстрые ноты вверх (ми–ля, кварта) — короткое «готово».
ding = mix(render([(659, 1.0, 0.09), (1318, 0.25, 0.05)], 0.18),
           render([(880, 1.0, 0.16), (1760, 0.22, 0.08)], 0.35), 0.08)

# Маримба: тёплое дерево, почти без обертонов.
marimba = render([(784, 1.0, 0.12), (1568, 0.3, 0.06), (2352, 0.1, 0.04)], 0.32)

for name, data in (("tick", tick), ("pop", pop),
                   ("ding", ding), ("marimba", marimba)):
    with wave.open(f"copy-{name}.wav", "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in data))
    print(f"copy-{name}: {len(data)/RATE:.2f} с")
