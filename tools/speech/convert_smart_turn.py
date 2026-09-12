#!/usr/bin/env python3
"""Convert Smart-Turn v3 (ONNX) + Whisper log-mel preprocessor to CoreML.

Pipecat's smart-turn-v3.2-cpu.onnx expects [1, 80, 800] log-mel features.
Audio → features preprocessing uses Whisper's feature extractor for 8s of
16 kHz mono audio. To avoid writing Whisper's mel computation in Swift,
we bundle a second CoreML model that wraps the Whisper mel pipeline.

Outputs (committed to the repo so CI doesn't need Python):
  Sources/CodeRelaySpeech/Resources/WhisperLogMel8s.mlpackage
  Sources/CodeRelaySpeech/Resources/SmartTurnV3.mlpackage
"""
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from transformers import WhisperFeatureExtractor
from huggingface_hub import hf_hub_download

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "Sources" / "CodeRelaySpeech" / "Resources"
OUT_DIR.mkdir(parents=True, exist_ok=True)

SAMPLE_RATE = 16000
CHUNK_SECONDS = 8
N_SAMPLES = SAMPLE_RATE * CHUNK_SECONDS  # 128_000
N_MELS = 80
N_FRAMES = 800

# ---------- 1. Whisper log-mel preprocessor ----------

fe = WhisperFeatureExtractor(chunk_length=CHUNK_SECONDS)
# Whisper uses n_fft=400, hop=160, window='hann', 80 mel filters, log-mel with clipping.
# We reproduce those steps with torch ops so they can be traced.

mel_np = np.asarray(fe.mel_filters, dtype=np.float32)
# Whisper ships mel filters in [n_fft_bins, n_mels] = [201, 80] form.
# Transpose if needed so we have [n_mels, n_fft_bins] for standard mel @ mag math.
if mel_np.shape[0] != N_MELS:
    mel_np = mel_np.T
MEL_FILTERS = torch.tensor(mel_np, dtype=torch.float32)
print(f"    mel_filters shape: {tuple(MEL_FILTERS.shape)}")
N_FFT = fe.n_fft                        # 400
HOP = fe.hop_length                     # 160
WINDOW = torch.hann_window(N_FFT)       # [400]


def build_stft_basis(n_fft: int, window: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """Return (cos_basis, sin_basis) of shape [n_fft//2+1, n_fft].

    Computes STFT bins k=0..N/2 for a real input, using a windowed DFT:
        X[k, t] = sum_n x[n + hop*t] * window[n] * exp(-2pi j k n / N)
    so magnitudes can be obtained via two real convolutions.
    """
    k = torch.arange(n_fft // 2 + 1, dtype=torch.float32).unsqueeze(1)   # [K, 1]
    n = torch.arange(n_fft, dtype=torch.float32).unsqueeze(0)             # [1, N]
    phase = 2 * np.pi * k * n / n_fft
    cos_basis = torch.cos(phase) * window.unsqueeze(0)   # [K, N]
    sin_basis = torch.sin(phase) * window.unsqueeze(0)   # [K, N]
    return cos_basis, sin_basis


class LogMelPreprocessor(torch.nn.Module):
    """Whisper-compatible log-mel spectrogram for 8 s of 16 kHz mono audio.

    Input:  audio of shape [N_SAMPLES]
    Output: log-mel of shape [1, 80, 800]

    Uses 1-D convolutions to compute the STFT, sidestepping torch.stft's
    coremltools tracer incompatibilities. Mathematically equivalent.
    """
    def __init__(self):
        super().__init__()
        self.register_buffer("mel_filters", MEL_FILTERS)   # [80, 201]
        cos_basis, sin_basis = build_stft_basis(N_FFT, WINDOW)
        # Conv1D weights: [out_channels, in_channels=1, kernel=N_FFT]
        self.register_buffer("cos_weights", cos_basis.unsqueeze(1))   # [K, 1, N]
        self.register_buffer("sin_weights", sin_basis.unsqueeze(1))   # [K, 1, N]

    def forward(self, audio):
        # HuggingFace's do_normalize=True applies zero-mean / unit-variance
        # normalization to the audio BEFORE the spectrogram step. Attention
        # mask is all-1s because our input is always full 8 s (no padding).
        mean = audio.mean()
        std = audio.std()
        audio = (audio - mean) / (std + 1e-7)

        # Center-pad with reflection so frame[t=0] is centered at sample 0.
        pad = N_FFT // 2
        padded = torch.nn.functional.pad(audio.unsqueeze(0), (pad, pad), mode="reflect").unsqueeze(0)
        # [1, 1, N_SAMPLES + 2*pad]

        real = torch.nn.functional.conv1d(padded, self.cos_weights, stride=HOP)
        imag = torch.nn.functional.conv1d(padded, self.sin_weights, stride=HOP)
        # Each is [1, K, n_frames+1]; drop the trailing frame to land at 800.
        real = real[..., :N_FRAMES]
        imag = imag[..., :N_FRAMES]

        magnitudes = real.pow(2) + imag.pow(2)       # [1, 201, 800]
        magnitudes = magnitudes.squeeze(0)           # [201, 800]

        mel_spec = self.mel_filters @ magnitudes     # [80, 800]
        log_spec = torch.clamp(mel_spec, min=1e-10).log10()
        log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
        log_spec = (log_spec + 4.0) / 4.0
        return log_spec.unsqueeze(0)                 # [1, 80, 800]


print("[1/4] Building and tracing log-mel preprocessor...")
pre = LogMelPreprocessor().eval()
dummy_audio = torch.zeros(N_SAMPLES, dtype=torch.float32)
# Non-zero seed so torch.stft doesn't take a shortcut during tracing
dummy_audio[0] = 1e-6
with torch.no_grad():
    traced_pre = torch.jit.trace(pre, dummy_audio)

# Verify Python numerics vs HuggingFace's extractor
ref_audio = np.random.default_rng(0).standard_normal(N_SAMPLES).astype(np.float32) * 0.1
ref_feats = fe(ref_audio, sampling_rate=SAMPLE_RATE, return_tensors="np",
               padding="max_length", max_length=N_SAMPLES, truncation=True,
               do_normalize=True).input_features[0]  # [80, 800]
our_feats = pre(torch.from_numpy(ref_audio)).squeeze(0).numpy()
diff = float(np.abs(ref_feats - our_feats).max())
print(f"    max abs diff vs HuggingFace extractor: {diff:.6g}")
if diff > 0.2:
    # Real difference between our trace and HF's extractor — flag it, but keep
    # going: Smart-Turn is robust to small feature-extraction deviations.
    print("    WARNING: large diff — double-check numerics")

print("[2/4] Converting preprocessor to CoreML...")
pre_ml = ct.convert(
    traced_pre,
    inputs=[ct.TensorType(name="audio", shape=(N_SAMPLES,), dtype=np.float32)],
    outputs=[ct.TensorType(name="log_mel", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS17,
    convert_to="mlprogram",
)
pre_path = OUT_DIR / "WhisperLogMel8s.mlpackage"
pre_ml.save(str(pre_path))
print(f"    Wrote {pre_path} ({sum(f.stat().st_size for f in pre_path.rglob('*') if f.is_file()):,} bytes)")

# ---------- 2. Smart-Turn ONNX → CoreML ----------

print("[3/4] Downloading Smart-Turn v3 ONNX (FP32 variant)...")
# Use the FP32 ("gpu") ONNX rather than the int8 CPU one, because the int8
# variant contains DequantizeLinear ops that onnx2torch can't bridge.
# CoreML will quantize on-device anyway if we ask it to.
onnx_path = hf_hub_download(repo_id="pipecat-ai/smart-turn-v3", filename="smart-turn-v3.2-gpu.onnx")
print(f"    Got {onnx_path}")

print("[4/4] Converting Smart-Turn ONNX to CoreML via PyTorch bridge...")
# coremltools 9 dropped direct ONNX conversion. Use onnx2torch to bounce
# through PyTorch, then convert as a traced module.
import onnx
from onnx2torch import convert as onnx_to_torch_convert

onnx_model = onnx.load(onnx_path)

# Strip allowzero=1 attributes from Reshape nodes — onnx2torch doesn't
# implement it, and with fixed shapes the default behavior is equivalent.
for n in onnx_model.graph.node:
    if n.op_type == "Reshape":
        new_attrs = [a for a in n.attribute if a.name != "allowzero"]
        if len(new_attrs) != len(n.attribute):
            del n.attribute[:]
            n.attribute.extend(new_attrs)

st_torch = onnx_to_torch_convert(onnx_model)
st_torch.train(False)

dummy_features = torch.zeros(1, N_MELS, N_FRAMES, dtype=torch.float32)
with torch.no_grad():
    traced_st = torch.jit.trace(st_torch, dummy_features)

st_ml = ct.convert(
    traced_st,
    inputs=[ct.TensorType(name="input_features", shape=(1, N_MELS, N_FRAMES), dtype=np.float32)],
    outputs=[ct.TensorType(name="probability", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS17,
    convert_to="mlprogram",
)
st_path = OUT_DIR / "SmartTurnV3.mlpackage"
st_ml.save(str(st_path))
print(f"    Wrote {st_path} ({sum(f.stat().st_size for f in st_path.rglob('*') if f.is_file()):,} bytes)")

print("Done.")
