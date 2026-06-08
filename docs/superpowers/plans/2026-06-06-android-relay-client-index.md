# Android Relay Client — Implementation Plan Index

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement each milestone plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-06-06-android-relay-client-design.md`

**⚠️ Errata (read before implementing):** `docs/superpowers/plans/2026-06-08-android-relay-client-corrections.md`
— a source-verified corrections pass (95 claims confirmed, ~20 corrected against the canonical
Swift source). It **supersedes** any spec/plan text it corrects. The inline fixes are applied
across the spec + M1–M4, but the corrections doc is the single place that explains each change
with `file:line` citations. Highest-impact: ServerMessage has **19** type strings (not 18);
AppSettings has **14** `@AppStorage` keys (not 18); `SessionNaming` is random + explicit
`fallbackIndex`; the four coordinator ops are **distinct sequences**; **RecoveryController is a
rewrite** (5 s probe, terminal auth/resume failure, cooldown, healthy-ping reset, cancel
semantics, send-suppression); Qwen is **≈0.5 GB**; add `WakeWordAudioPreprocessor` + `ProcessedText`.

**Goal:** Build an Android client at exact feature parity with the iOS Claude Relay app. The server and WebSocket protocol are frozen; Android is a pure new client.

This work is decomposed into **four milestone plans**, each producing working, testable software on its own. Implement them in order — each builds on the previous.

| Plan | Milestone | Produces |
|---|---|---|
| `2026-06-06-android-relay-client-m1-protocol-net-terminal.md` | **M1** | Project scaffold + `:core-protocol` + `:core-net` + `:core-storage` + a live terminal (`:terminal`). Deliverable: connect to a server, see + type in a live terminal. |
| `2026-06-06-android-relay-client-m2-sessions-recovery-ui.md` | **M2** | `:core-session` (full recovery state machine) + sessions/tabs/sidebar + QR + deep links + adaptive Compose UI + settings. Deliverable: full session management + recovery parity (no speech). |
| `2026-06-06-android-relay-client-m3-speech.md` | **M3** | `:speech` — capture, whisper.cpp, Silero VAD, PTT + continuous state machine, Bedrock + llama.cpp cleanup; CoreML→ONNX conversion sub-project behind a parity gate. Deliverable: on-device speech input. |
| `2026-06-06-android-relay-client-m4-parity-polish.md` | **M4** | SmartTurn/LogMel parity-validated & enabled, polish, accessibility, haptics, animations, edge-case hardening. Deliverable: 100% parity → public launch. |

## Conventions used across all plans

- **Reference repo (Swift source of truth):** the existing iOS/Mac codebase in this repo. When a plan says "port `RelayConnection.swift`", the canonical behavior is the Swift file at `Sources/ClaudeRelayClient/RelayConnection.swift`.
- **Android project location (monorepo):** a top-level `ClaudeRelayAndroid/` directory **inside this existing repository**, alongside `Sources/`, `ClaudeRelayApp/`, and `ClaudeRelayMac/`. It has its own Gradle build and its own CI workflow (separate GitHub Actions job — not entangled with the Swift pipeline). Plan paths are relative to `ClaudeRelayAndroid/` unless they reference a Swift artifact (e.g. `Sources/ClaudeRelaySpeech/Resources/…`), which is reachable directly because it's the same repo. See the spec's "Repository layout" section for the rationale.
- **Language/build:** Kotlin, Gradle (Kotlin DSL), Jetpack Compose, Hilt, JUnit5 + Turbine + MockK for tests, kotlinx.serialization.
- **TDD:** every behavioral task writes a failing test first. UI-only and JNI-glue tasks that cannot be unit-tested note this explicitly and specify a manual verification step instead.
- **Commits:** frequent, one per task (or per logical step within a large task).

## Execution-time prerequisites (decide once, before M1 Task 1)

1. **Android Studio** (latest stable) + JDK 17.
2. **A running Claude Relay server** reachable from the dev machine/emulator, with an auth token (`swift run claude-relay token create --port 9100 --label "android-dev"`). Used for the M1 contract test (capturing a real frame) and all manual verification.
3. **NDK** (for M3 JNI: whisper.cpp / llama.cpp).
4. Confirm the **minSdk** (spec says 26–28; pick one and pin in M1 Task 1).
