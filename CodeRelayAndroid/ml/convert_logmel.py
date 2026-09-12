#!/usr/bin/env python3
"""Convert WhisperLogMel8s.mlpackage to ONNX for the Android :speech module.

M4-GATED TOOLING — NOT RUN IN THE M3 ENV (no coremltools/onnxruntime installed).
Runnable on a Mac with: ``pip install coremltools onnx onnxruntime numpy``.

This is the Whisper log-mel front end: it turns 8 s of 16 kHz mono audio into the
[1, 80, 800] log-mel feature tensor that the Smart-Turn classifier consumes.

Conversion strategy
-------------------
coremltools dropped its direct ``MLModel -> ONNX`` exporter, so we reconstruct
the same deterministic STFT + mel-filterbank + log graph that the CoreML model
implements (it is a fixed signal-processing front end with NO learned weights
other than the mel filter matrix). We:

  1. Introspect ``WhisperLogMel8s.mlpackage`` via coremltools to READ its exact
     input/output spec + the baked-in mel-filter weights (so the ONNX matches
     bit-for-bit-ish, validated later by validate_parity.py).
  2. Build an equivalent PyTorch module implementing Whisper's standard log-mel
     (n_fft=400, hop=160, n_mels=80, 8 s -> 800 frames) seeded with those exact
     mel filters, and export it to ONNX via ``torch.onnx.export``.

Whisper log-mel parameters (canonical, openai/whisper):
    n_fft   = 400      (25 ms window @ 16 kHz)
    hop     = 160      (10 ms hop)
    n_mels  = 80
    frames  = 1 + 128000 // 160 = 801 -> Whisper drops the last frame -> 800

Output contract (MUST match SmartTurnTurnEndDetector.kt's LOGMEL stage):
    input  : audio   [1, 128000]   float32
    output : log_mel [1, 80, 800]  float32
"""

from __future__ import annotations

import sys

import _common as C

# Whisper standard log-mel parameters (must match the CoreML model's baked config).
N_FFT = 400
HOP = 160
N_MELS = 80


def _read_coreml_spec_and_filters():
    """Introspect the CoreML package: return (spec, mel_filter_matrix [80, 201])."""
    import coremltools as ct
    import numpy as np

    C.require_source(C.LOGMEL_MLPACKAGE)
    model = ct.models.MLModel(C.LOGMEL_MLPACKAGE)
    spec = model.get_spec()

    # Locate the mel-filter constant in the MIL program. Whisper's mel matrix is
    # [n_mels, n_fft//2 + 1] = [80, 201]. We scan the program's immediate-value
    # tensors for the one matching that shape.
    mel = None
    try:
        prog = spec.mlProgram  # CoreML 5+ ML program
        for fn in prog.functions.values():
            for op in fn.block_specializations.values():
                for operation in op.operations:
                    for val in operation.attributes.values():
                        t = getattr(val, "immediateValue", None)
                        if t is None:
                            continue
                        flat = np.array(t.tensor.floats.values, dtype=np.float32)
                        if flat.size == N_MELS * (N_FFT // 2 + 1):
                            mel = flat.reshape(N_MELS, N_FFT // 2 + 1)
    except Exception:  # noqa: BLE001 — fall through to librosa filters below
        mel = None

    if mel is None:
        print(
            "  could not extract baked mel filters from CoreML program; "
            "falling back to librosa.filters.mel (standard Whisper filters)."
        )
        import librosa

        mel = librosa.filters.mel(sr=C.SAMPLE_RATE, n_fft=N_FFT, n_mels=N_MELS).astype(
            "float32"
        )
    return spec, mel


def _build_torch_logmel(mel_filters):
    """A torch module implementing Whisper log-mel seeded with the given filters."""
    import torch

    mel_t = torch.from_numpy(mel_filters)

    class LogMel(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.register_buffer("window", torch.hann_window(N_FFT))
            self.register_buffer("mel_filters", mel_t)

        def forward(self, audio: "torch.Tensor") -> "torch.Tensor":
            # audio: [1, 128000]
            stft = torch.stft(
                audio.squeeze(0),
                n_fft=N_FFT,
                hop_length=HOP,
                window=self.window,
                return_complex=True,
            )
            magnitudes = stft[..., :-1].abs() ** 2  # drop last frame -> 800
            mel_spec = self.mel_filters @ magnitudes  # [80, 800]
            log_spec = torch.clamp(mel_spec, min=1e-10).log10()
            log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
            log_spec = (log_spec + 4.0) / 4.0
            return log_spec.unsqueeze(0)  # [1, 80, 800]

    return LogMel().eval()


def _export_and_check(module) -> None:
    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch

    dummy = torch.zeros(1, C.LOGMEL_SAMPLES, dtype=torch.float32)
    torch.onnx.export(
        module,
        dummy,
        C.LOGMEL_ONNX,
        input_names=[C.LOGMEL_INPUT],
        output_names=[C.LOGMEL_OUTPUT],
        opset_version=17,
        dynamic_axes=None,  # fixed 8 s window
    )

    model = onnx.load(C.LOGMEL_ONNX)
    onnx.checker.check_model(model)

    sess = ort.InferenceSession(C.LOGMEL_ONNX, providers=["CPUExecutionProvider"])
    out = sess.run(None, {C.LOGMEL_INPUT: np.zeros((1, C.LOGMEL_SAMPLES), np.float32)})[0]
    if tuple(out.shape) != C.LOGMEL_OUTPUT_SHAPE:
        raise AssertionError(
            f"log_mel output shape {out.shape} != expected {C.LOGMEL_OUTPUT_SHAPE}"
        )
    print(f"  contract OK: log_mel shape {out.shape} == {C.LOGMEL_OUTPUT_SHAPE}")


def main() -> int:
    C.banner("convert_logmel.py — WhisperLogMel8s -> ONNX")
    C.ensure_out_dir()

    _spec, mel = _read_coreml_spec_and_filters()
    print(f"  mel filter matrix: {mel.shape}")
    module = _build_torch_logmel(mel)
    _export_and_check(module)

    print(f"\nwrote {C.LOGMEL_ONNX}")
    print("NOTE: GATED — log-mel max-abs diff vs CoreML is asserted by")
    print("      ml/validate_parity.py; not trusted until that passes (M4).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
