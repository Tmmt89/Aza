"""Aza's optional, offline ASR worker. Audio travels only through stdin/stdout."""

import contextlib
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import urllib.request

OUTPUT = sys.stdout
MODELS = {
    "ctc": ("omniASR_CTC_1B_v2", "omniASR-CTC-1B-v2.pt"),
    "llm": ("omniASR_LLM_1B_v2", "omniASR-LLM-1B-v2.pt"),
}
RATE = 16000
MAX_SAMPLES = 30 * 60 * RATE
ASSETS = {
    "omniASR-CTC-1B-v2.pt": "354f981756aa8f41591ea363e45b9c4eba1ec5144c2273af82e747efbb08919c",
    "omniASR-LLM-1B-v2.pt": "cceb4d9ebac3d168a6af6b26c62ce11bafc562b38976c6bfa87e7d60422c6da5",
    "omniASR_tokenizer_written_v2.model": "8aa11a1092142ef472537476ef6e76541123e2f0d789b79f3ebd119008240b1e",
}
ALPHABET = frozenset("абвгдеёжзийклмнопрстуфхцчшщъыьэюяӏ"
                     + "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯӀ"
                     + "0123456789 \n\t.,!?;:—–-«»\"'’()[]/…+%=№")


def assets_for(variant):
    return {name: ASSETS[name] for name in
            (MODELS[variant][1], "omniASR_tokenizer_written_v2.model")}


def alphabet_mask(tokenizer):
    """Keep CTC blank/BOS, padding and EOS; block unknown and foreign-script tokens."""
    import torch
    vocab = tokenizer.vocab_info
    special = {vocab.bos_idx, vocab.pad_idx, vocab.eos_idx}
    decode = tokenizer.create_decoder()
    allowed = []
    for index in range(vocab.size):
        text = decode(torch.tensor([index]))
        allowed.append(index in special or (bool(text) and all(c in ALPHABET for c in text)))
    allowed[vocab.unk_idx] = False
    return torch.tensor(allowed, dtype=torch.bool)


def constrain_alphabet(model, tokenizer):
    import torch
    allowed = alphabet_mask(tokenizer)
    def restrict(_module, _inputs, logits):
        if logits.shape[-1] != allowed.numel():
            raise ValueError("Словарь модели не совпадает с ограничением алфавита.")
        return logits.masked_fill(~allowed.to(logits.device), -torch.inf)
    model.final_proj.register_forward_hook(restrict)


def emit(**message):
    print(json.dumps(message, ensure_ascii=False), file=OUTPUT, flush=True)


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def download(root, name, expected):
    target = root / name
    if target.is_file() and digest(target) == expected:
        return
    partial = target.with_suffix(target.suffix + ".partial")
    try:
        request = urllib.request.Request("https://dl.fbaipublicfiles.com/mms/" + name)
        with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
            total = int(response.headers.get("Content-Length", 0))
            received, percent = 0, -1
            while block := response.read(1024 * 1024):
                output.write(block)
                received += len(block)
                current = int(received * 100 / total) if total else 0
                if current != percent:
                    percent = current
                    emit(status="Скачиваю модель чеченского…", progress=min(current / 100, 1))
        if digest(partial) != expected:
            raise ValueError("Контрольная сумма модели не совпала. Нажмите «Скачать» ещё раз.")
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)


def load_pipeline(root, variant="ctc"):
    # soundfile's wheel contains libsndfile; no Homebrew or system-library edits.
    import site
    packages = Path(site.getsitepackages()[0])
    library = packages.parent.parent / "libsndfile.1.dylib"
    if not library.exists():
        library.symlink_to(packages / "_soundfile_data" / "libsndfile_arm64.dylib")

    # Also enforce offline inference if a dependency tries to repair its cache.
    def offline(event, args):
        if event in ("socket.connect", "socket.getaddrinfo", "socket.bind"):
            raise RuntimeError("Распознавание работает без доступа к сети.")
    sys.addaudithook(offline)

    import torch
    from fairseq2.models.wav2vec2.asr import get_wav2vec2_asr_model_hub
    from fairseq2.data.tokenizers.char import load_char_tokenizer
    from omnilingual_asr.models.inference.pipeline import ASRInferencePipeline
    from omnilingual_asr.models.wav2vec2_llama import get_wav2vec2_llama_model_hub

    torch.set_num_threads(min(8, os.cpu_count() or 1))
    # fairseq2 0.6's file-URI loader does not decode %20. Native paths also
    # preserve Unicode, literal percent signs and URI delimiters in user folders.
    name, checkpoint = MODELS[variant]
    hub = get_wav2vec2_asr_model_hub() if variant == "ctc" else get_wav2vec2_llama_model_hub()
    model = hub.load_custom_model(root / checkpoint, hub.get_model_config(name),
                                  device=torch.device("cpu"), dtype=torch.float32, progress=False)
    tokenizer = load_char_tokenizer(root / "omniASR_tokenizer_written_v2.model", None)
    # This restricts the writing system, not the language understood by the encoder.
    constrain_alphabet(model, tokenizer)
    return ASRInferencePipeline(None, model=model, tokenizer=tokenizer,
                                device="cpu", dtype=torch.float32)


def audio_chunks(audio):
    """Keep every sample; choose a quiet boundary between 20 and 30 seconds."""
    import numpy as np
    start = 0
    while len(audio) - start > 30 * RATE:
        low, high, window = start + 20 * RATE, start + 30 * RATE, RATE // 10
        boundaries = range(low, high, window)
        # ponytail: energy minimum can split a word in continuous speech; use VAD if needed.
        end = min(boundaries, key=lambda p: float(np.mean(audio[p:p + window] ** 2))) + window // 2
        yield audio[start:end]
        start = end
    if start < len(audio):
        yield audio[start:]


def transcribe(root, variant):
    import numpy as np
    raw = sys.stdin.buffer.read(MAX_SAMPLES * 4 + 1)
    if not raw or len(raw) % 4 or len(raw) > MAX_SAMPLES * 4:
        raise ValueError("Некорректное аудио: ожидается запись до 30 минут.")
    audio = np.frombuffer(raw, dtype="<f4")
    if not np.isfinite(audio).all():
        raise ValueError("Запись содержит некорректные сэмплы.")
    emit(status="Готовлю модель чеченского…")
    pipeline = load_pipeline(root, variant)
    emit(status="Распознаю чеченскую речь…")
    texts = []
    processed = 0
    for chunk in audio_chunks(audio):
        # Match Aza's silence gate so long pauses cannot produce invented text.
        if any(float(np.mean(chunk[p:p + 1600] ** 2)) >= 0.005 ** 2
               for p in range(0, len(chunk), 1600)):
            texts.append(pipeline.transcribe([{"waveform": chunk.copy(), "sample_rate": RATE}],
                                              lang=["che_Cyrl"] if variant == "llm" else None,
                                              batch_size=1)[0].strip())
        processed += len(chunk)
        emit(status=f"Распознаю чеченскую речь: {int(processed * 100 / len(audio))}%")
    text = " ".join(text for text in texts if text)
    if any(c not in ALPHABET for c in text):
        raise ValueError("Модель вернула символы вне русского и чеченского алфавита.")
    emit(text=text)


def install(root, requirements, variant):
    emit(status="Устанавливаю компоненты распознавания…")
    # Upstream 0.2.0 says <=3.12 instead of <3.13, excluding every 3.12 patch release.
    # The lock is resolved for 3.12; binary-only cp312 wheels and the real load check still apply.
    subprocess.run([sys.executable, "-I", "-m", "pip", "--isolated", "install",
        "--disable-pip-version-check", "--no-cache-dir", "--no-deps", "--require-hashes",
        "--only-binary=:all:", "--ignore-requires-python", "-r", requirements],
        check=True, stdout=sys.stderr)
    for name, expected in assets_for(variant).items():
        download(root, name, expected)
    emit(status="Проверяю модель чеченского…")
    load_pipeline(root, variant)
    emit(installed=True)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("install", "transcribe"):
        raise ValueError("Некорректная команда распознавания.")
    expected = 5 if sys.argv[1] == "install" else 4
    if len(sys.argv) != expected or sys.argv[-1] not in MODELS:
        raise ValueError("Некорректный вариант распознавания.")
    variant = sys.argv[-1]
    root = Path(sys.argv[2]).resolve()
    os.environ["FAIRSEQ2_CACHE_DIR"] = str(root / "cache")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    # Each worker owns its process group, including pip; cancellation kills all children.
    try:
        os.setsid()
    except PermissionError:
        if os.getpgrp() != os.getpid():
            raise
    signal.signal(signal.SIGTERM, lambda *_: os.killpg(os.getpid(), signal.SIGKILL))
    parent = os.getppid()
    def watch_parent():
        while os.getppid() == parent:
            time.sleep(1)
        os.killpg(os.getpid(), signal.SIGKILL)
    threading.Thread(target=watch_parent, daemon=True).start()
    with contextlib.redirect_stdout(sys.stderr):
        if sys.argv[1] == "install":
            install(root, sys.argv[3], variant)
        else:
            transcribe(root, variant)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit(error=f"OmniASR: {type(error).__name__}: {error}")
        sys.exit(1)
