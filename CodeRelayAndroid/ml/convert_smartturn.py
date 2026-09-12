#!/usr/bin/env python3
"""Convert SmartTurnV3.mlpackage (pipecat-ai/smart-turn v3) to ONNX.

M4-GATED TOOLING — NOT RUN IN THE M3 ENV (no coremltools/onnxruntime installed).
Runnable on a Mac with: ``pip install coremltools onnx onnxruntime numpy torch transformers``.

Smart-Turn v3 is a Whisper-Tiny encoder + a small linear classification head that
emits a single sigmoid probability of "speaker finished their turn".

Conversion strategy
-------------------
The in-repo CoreML model has fp16 weights baked in. We:

  1. Introspect ``SmartTurnV3.mlpackage`` via coremltools to confirm its exact
     I/O spec (input ``input_features [1, 80, 800]`` -> output ``probability``).
  2. PREFERRED — re-export the canonical upstream ``pipecat-ai/smart-turn-v3``
     PyTorch checkpoint to ONNX via ``torch.onnx.export`` (matching the same
     architecture the CoreML model was built from). This avoids the
     ``coremltools -> ONNX`` exporter that no longer exists, and gives an fp32
     ONNX whose numerics validate_parity.py can compare against the CoreML fp16.
  3. The exported graph ends in a SIGMOID so ``probability`` is already in [0, 1];
     the 0.5 decision threshold lives in the consuming code
     (``SmartTurnTurnEndDetector.thresholdToResult`` / ``SMARTTURN_THRESHOLD``),
     NOT baked into the model.

Output contract (MUST match SmartTurnTurnEndDetector.kt's classifier stage):
    input  : input_features [1, 80, 800]  float32  (the log_mel from convert_logmel.py)
    output : probability    [1, 1]        float32  (sigmoid, threshold 0.5 in caller)
"""

from __future__ import annotations

import sys

import _common as C

# Canonical upstream checkpoint the CoreML model was built from.
UPSTREAM_REPO = "pipecat-ai/smart-turn-v3"


def _confirm_coreml_spec() -> None:
    """Introspect the CoreML model and confirm the I/O names we depend on."""
    import coremltools as ct

    C.require_source(C.SMARTTURN_MLPACKAGE)
    model = ct.models.MLModel(C.SMARTTURN_MLPACKAGE)
    spec = model.get_spec()
    in_names = [i.name for i in spec.description.input]
    out_names = [o.name for o in spec.description.output]
    print(f"  CoreML inputs : {in_names}")
    print(f"  CoreML outputs: {out_names}")
    if C.SMARTTURN_INPUT not in in_names:
        raise AssertionError(
            f"CoreML input '{C.SMARTTURN_INPUT}' not found in {in_names}"
        )
    if C.SMARTTURN_OUTPUT not in out_names:
        raise AssertionError(
            f"CoreML output '{C.SMARTTURN_OUTPUT}' not found in {out_names}"
        )


def _load_upstream_module():
    """Load the upstream smart-turn-v3 classifier (Whisper-Tiny encoder + head)."""
    import torch
    from transformers import WhisperModel

    encoder = WhisperModel.from_pretrained("openai/whisper-tiny").encoder

    class SmartTurn(torch.nn.Module):
        """Whisper-Tiny encoder + mean-pool + linear head + sigmoid."""

        def __init__(self) -> None:
            super().__init__()
            self.encoder = encoder
            hidden = encoder.config.d_model
            self.head = torch.nn.Linear(hidden, 1)
            # NOTE: in a real M4 run, load the upstream fine-tuned weights for the
            # head + encoder from `UPSTREAM_REPO` (state_dict). The architecture
            # here is the contract; validate_parity.py is what proves the numerics.

        def forward(self, input_features: "torch.Tensor") -> "torch.Tensor":
            # input_features: [1, 80, 800]
            enc = self.encoder(input_features).last_hidden_state  # [1, T, H]
            pooled = enc.mean(dim=1)  # [1, H]
            logits = self.head(pooled)  # [1, 1]
            return torch.sigmoid(logits)  # probability in [0, 1]

    return SmartTurn().eval()


def _export_and_check(module) -> None:
    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch

    dummy = torch.zeros(1, *C.SMARTTURN_INPUT_SHAPE[1:], dtype=torch.float32)
    torch.onnx.export(
        module,
        dummy,
        C.SMARTTURN_ONNX,
        input_names=[C.SMARTTURN_INPUT],
        output_names=[C.SMARTTURN_OUTPUT],
        opset_version=17,
        dynamic_axes=None,
    )

    model = onnx.load(C.SMARTTURN_ONNX)
    onnx.checker.check_model(model)

    sess = ort.InferenceSession(C.SMARTTURN_ONNX, providers=["CPUExecutionProvider"])
    feats = np.zeros((1, *C.SMARTTURN_INPUT_SHAPE[1:]), np.float32)
    out = sess.run(None, {C.SMARTTURN_INPUT: feats})[0]
    prob = float(np.ravel(out)[0])
    if not (0.0 <= prob <= 1.0):
        raise AssertionError(f"probability {prob} not in [0, 1] — missing sigmoid?")
    print(f"  contract OK: probability={prob:.4f} in [0, 1] (sigmoid); "
          f"threshold {C.SMARTTURN_THRESHOLD} applied in the Kotlin caller")


def main() -> int:
    C.banner("convert_smartturn.py — SmartTurnV3 -> ONNX")
    C.ensure_out_dir()

    _confirm_coreml_spec()
    module = _load_upstream_module()
    _export_and_check(module)

    print(f"\nwrote {C.SMARTTURN_ONNX}")
    print("NOTE: GATED — SmartTurn is NOT trusted until ml/validate_parity.py")
    print("      proves TPR >= 90% / FPR <= 10% vs labels (M4). The architecture")
    print(f"      here is the contract; load upstream weights from {UPSTREAM_REPO}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
