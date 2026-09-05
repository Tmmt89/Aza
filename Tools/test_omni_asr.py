"""Audio checks; pass a model directory and ctc/llm to check its alphabet and real loading."""
import importlib.util
from pathlib import Path
import sys
import tempfile

import numpy as np

path = Path(__file__).resolve().parents[1] / "Aza/Resources/omni-asr.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("omni_worker", path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

for seconds in [0, 0.3, 2.4, 30, 30.01, 61, 1800]:
    # Distinct samples catch omissions, overlap and accidental reordering.
    audio = np.arange(int(seconds * worker.RATE), dtype=np.float32)
    chunks = list(worker.audio_chunks(audio))
    assert all(0 < len(chunk) <= 30 * worker.RATE for chunk in chunks)
    assert np.array_equal(np.concatenate(chunks) if chunks else np.array([]), audio)

audio = np.ones(65 * worker.RATE, dtype=np.float32)
audio[25 * worker.RATE:26 * worker.RATE] = 0
chunks = list(worker.audio_chunks(audio))
assert 25 * worker.RATE <= len(chunks[0]) <= 26 * worker.RATE
assert np.array_equal(np.concatenate(chunks), audio)
print("PASS: OmniASR chunk boundaries preserve all samples and use a pause")

if len(sys.argv) > 1:
    root = Path(sys.argv[1]).resolve()
    variant = sys.argv[2] if len(sys.argv) > 2 else "ctc"
    import torch
    from types import SimpleNamespace
    from fairseq2.data.tokenizers.char import load_char_tokenizer
    tokenizer = load_char_tokenizer(root / "omniASR_tokenizer_written_v2.model", None)
    allowed = worker.alphabet_mask(tokenizer)
    def token(char):
        indices = tokenizer.create_encoder()(char).tolist()
        assert len(indices) == 1 and indices[0] != tokenizer.vocab_info.unk_idx, char
        return indices[0]
    for char in "аАёЁӏӀ":
        assert allowed[token(char)], char
    for char in "عאa中і":
        assert not allowed[token(char)], char
    vocab = tokenizer.vocab_info
    assert allowed[vocab.bos_idx] and allowed[vocab.eos_idx] and allowed[vocab.pad_idx]
    assert not allowed[vocab.unk_idx]
    assert any(allowed[i] and tokenizer.create_decoder()(torch.tensor([i])) == " " for i in range(vocab.size))
    # A foreign symbol wins acoustically; the decoder must choose the permitted
    # alternative, while the CTC blank preserves two repeated letters.
    fake = SimpleNamespace(final_proj=torch.nn.Identity())
    worker.constrain_alphabet(fake, tokenizer)
    logits = torch.full((1, 3, vocab.size), -20.0)
    logits[0, :, token("ع")] = 100
    logits[0, 0, token("а")] = logits[0, 2, token("а")] = 10
    logits[0, 1, vocab.bos_idx] = 10
    output = fake.final_proj(logits)
    assert torch.isneginf(output[..., token("ع")]).all()
    assert tokenizer.create_decoder()(output.argmax(-1)[0].unique_consecutive()) == "аа"
    print("PASS: alphabet restriction changes decoding and preserves CTC blank, EOS, palochka and spaces")
    with tempfile.TemporaryDirectory(prefix="Aza Application Support чеченский %20 #? ") as temporary:
        local = Path(temporary)
        for name, expected in worker.assets_for(variant).items():
            source = root / name
            assert worker.digest(source) == expected, "Invalid model asset: " + name
            (local / name).symlink_to(source)
        pipeline = worker.load_pipeline(local, variant)
        assert pipeline.model is not None and pipeline.tokenizer is not None
        if variant == "llm":
            from omnilingual_asr.models.wav2vec2_llama.syntax import lang_id_getter
            assert pipeline.model.lang_embeddings is not None
            assert lang_id_getter(pipeline.model.lang_mapping, "che_Cyrl") > 0
        print("PASS: real checkpoint and tokenizer load offline from spaces, Unicode, %, # and ?")
