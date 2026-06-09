package relay.speech.audio

/**
 * EXECUTION NOTE — audio capture contract (DEVICE-DEFERRED, do NOT implement in Task 1).
 *
 * The microphone-capture layer is implemented in a later milestone task and is
 * deferred here because it needs a physical device (no emulator in this env, and
 * audio capture cannot be unit-tested offline). This file documents the contract
 * the implementation must satisfy so the pure-logic [StreamingAudioBuffer] (the
 * Task-1 deliverable) has a defined consumer.
 *
 * Ports of:
 * - `Sources/ClaudeRelaySpeech/StreamingAudioSource.swift` (AVAudioEngine tap →
 *   16 kHz mono Float32 chunks, `onChunk` / `onInterruption` callbacks).
 * - `Sources/ClaudeRelaySpeech/AudioCaptureSession.swift` (accumulating capture
 *   with min/max duration guards).
 *
 * Contract for the deferred Android implementation
 * (`AudioCaptureSession` / `StreamingAudioSource` / `Resampler`):
 *
 *  1. Backend: wrap **Oboe** (preferred — low-latency C++ audio via AAR, no CMake
 *     needed by the consumer) or fall back to **AudioRecord**. The hardware
 *     typically delivers 44.1/48 kHz; a `Resampler` converts to 16 kHz mono
 *     Float32 (the Whisper/Smart-Turn input format). This mirrors the Swift
 *     `AVAudioConverter` step (`hardwareFormat -> 16 kHz mono Float32`).
 *
 *  2. Delivery: each converted chunk is pushed to [StreamingAudioBuffer.append]
 *     AND surfaced via an `onChunk: (FloatArray) -> Unit` callback (analog of
 *     `StreamingAudioSource.onChunk`). Chunk size is hardware-driven; consumers
 *     must handle any size. Swift uses a 4096-frame tap buffer as a starting
 *     point.
 *
 *  3. Interruptions: observe `AudioManager` audio-focus changes
 *     (`OnAudioFocusChangeListener`) — the Android analog of iOS
 *     `AVAudioSession.interruptionNotification`. On `AUDIOFOCUS_LOSS` /
 *     `AUDIOFOCUS_LOSS_TRANSIENT`, emit a "began" interruption (pause); on
 *     `AUDIOFOCUS_GAIN`, emit an "ended(shouldResume)" event. Mirrors
 *     `StreamingAudioSource.InterruptionEvent { began, ended(shouldResume) }`.
 *
 *  4. Auto-stop cap: retain the 5-minute (300 s) `maximumDuration` ceiling from
 *     `AudioCaptureSession.swift`. A backgrounded recording that never calls
 *     `stop()` would otherwise grow Float-sample memory at ~64 KB/s
 *     (16 kHz x 4 bytes x 1 channel). Also retain the 0.5 s `minimumDuration`
 *     floor that rejects empty/too-short captures.
 *
 *  5. Foreground-only: the capture engine starts on a foreground signal (the
 *     iOS apps gate on `scenePhase == .active`); no background-audio entitlement
 *     is used. The Android implementation should bind capture to a foreground
 *     lifecycle / foreground service, started in M3-F.
 *
 * None of the above is implemented here. Task 1 ships ONLY the pure-logic ring
 * buffer plus this contract.
 */
internal object AudioCaptureContract
