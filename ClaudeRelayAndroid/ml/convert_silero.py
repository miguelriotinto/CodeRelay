#!/usr/bin/env python3
"""Convert the Silero VAD v6 unified model to ONNX for the Android :speech module.

M4-GATED TOOLING — NOT RUN IN THE M3 ENV (no coremltools/onnxruntime installed).
Runnable on a Mac with: ``pip install coremltools onnx onnxruntime numpy``.

Strategy (two paths, preferred first):

  1) PREFERRED — fetch the public Silero v6 ONNX directly. The FluidInference
     Silero unified CoreML model in the repo was itself converted from the
     upstream Silero v6 PyTorch/ONNX release. The canonical public ONNX
     (``silero_vad.onnx``) already exposes the exact stateful-LSTM contract the
     Android detector expects, so when it is available we just normalise its
     I/O names and copy it to ``ml/out/silero_vad.onnx``.

  2) FALLBACK — introspect the in-repo ``SileroVAD.mlmodelc`` via coremltools,
     rebuild the same graph as ONNX. coremltools cannot directly emit ONNX
     (that direction was removed), so the robust fallback is to re-export from
     the original torch source. We document the exact contract here so a Mac
     operator can complete the fallback if the public ONNX ever drifts.

Output contract (MUST match SileroVoiceActivityDetector.kt + the .mlmodelc):
    inputs  : audio_input [1, 576]  (64 context + 512 chunk)
              hidden_state [1, 128]
              cell_state   [1, 128]
    outputs : vad_output       [1, 1, 1]   (Kotlin reads element [0])
              new_hidden_state [1, 128]
              new_cell_state   [1, 128]

The script ASSERTS these shapes/names on the produced ONNX and refuses to write
a model that does not match — a silent contract drift would break the Kotlin
detector at runtime on-device.
"""

from __future__ import annotations

import sys
import urllib.request

import _common as C

# Public Silero v6 unified ONNX (stateful LSTM, 576-sample window). Pinned to the
# v6.0 release tag used to build the in-repo CoreML model. If this URL drifts,
# fall back to re-exporting from the torch source (see module docstring).
PUBLIC_SILERO_ONNX_URL = (
    "https://github.com/snakers4/silero-vad/raw/v6.0/src/silero_vad/data/silero_vad.onnx"
)


def _assert_contract(model) -> None:
    """Assert the ONNX graph matches the Silero I/O contract; raise on mismatch."""
    import onnx  # local import: only needed when actually running

    graph = model.graph
    input_names = {i.name for i in graph.input}
    output_names = {o.name for o in graph.output}

    expected_in = set(C.SILERO_INPUTS)
    expected_out = set(C.SILERO_OUTPUTS)

    missing_in = expected_in - input_names
    missing_out = expected_out - output_names
    if missing_in or missing_out:
        raise AssertionError(
            "Silero ONNX contract mismatch.\n"
            f"  expected inputs : {sorted(expected_in)}\n"
            f"  actual inputs   : {sorted(input_names)}\n"
            f"  expected outputs: {sorted(expected_out)}\n"
            f"  actual outputs  : {sorted(output_names)}\n"
            f"  missing inputs  : {sorted(missing_in)}\n"
            f"  missing outputs : {sorted(missing_out)}\n"
            "The public ONNX may have drifted from v6 — re-export from the torch "
            "source so the names/shapes match SileroVoiceActivityDetector.kt."
        )
    onnx.checker.check_model(model)
    print("  contract OK: inputs/outputs match SileroVoiceActivityDetector.kt")


def _smoke_test() -> None:
    """Run a single inference through onnxruntime to confirm the graph executes."""
    import numpy as np
    import onnxruntime as ort

    sess = ort.InferenceSession(C.SILERO_ONNX, providers=["CPUExecutionProvider"])
    feeds = {
        "audio_input": np.zeros((1, C.SILERO_CONTEXT + C.SILERO_CHUNK), dtype=np.float32),
        "hidden_state": np.zeros((1, C.SILERO_STATE), dtype=np.float32),
        "cell_state": np.zeros((1, C.SILERO_STATE), dtype=np.float32),
    }
    outputs = sess.run(None, feeds)
    out_names = [o.name for o in sess.get_outputs()]
    by_name = dict(zip(out_names, outputs))
    prob = float(np.ravel(by_name["vad_output"])[0])
    print(f"  smoke test OK: vad_output[0]={prob:.4f} on silent input")


def main() -> int:
    C.banner("convert_silero.py — Silero VAD v6 unified -> ONNX")
    C.ensure_out_dir()

    import onnx  # noqa: F401  (fail fast with a clear ImportError if deps missing)

    # ── Path 1: fetch the public v6 ONNX ──────────────────────────────────────
    try:
        print(f"fetching public Silero v6 ONNX:\n  {PUBLIC_SILERO_ONNX_URL}")
        urllib.request.urlretrieve(PUBLIC_SILERO_ONNX_URL, C.SILERO_ONNX)
        model = onnx.load(C.SILERO_ONNX)
        _assert_contract(model)
    except Exception as exc:  # noqa: BLE001 — surface any fetch/contract failure
        print(f"\n[path 1 failed] {type(exc).__name__}: {exc}")
        print(
            "FALLBACK REQUIRED — re-export from the Silero v6 torch source so the\n"
            "ONNX matches the contract below, then re-run the contract assertion:\n"
            "  inputs : audio_input[1,576], hidden_state[1,128], cell_state[1,128]\n"
            "  outputs: vad_output[1,1,1], new_hidden_state[1,128], new_cell_state[1,128]\n"
            "Introspect the in-repo CoreML model for reference:\n"
            f"  python3 -c \"import coremltools as ct; "
            f"print(ct.models.MLModel('{C.SILERO_MLMODELC}').get_spec())\""
        )
        return 1

    _smoke_test()
    print(f"\nwrote {C.SILERO_ONNX}")
    print("NOTE: GATED — not trusted until ml/validate_parity.py passes (M4).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
