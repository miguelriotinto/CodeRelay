# Releasing the ClaudeRelay Android client

This document covers the **human-only** steps to ship a release build to Google
Play. The build configuration (release buildType, R8 / ProGuard keep rules,
versioning, and signing-from-env wiring) already lives in the repo:

- `app/build.gradle.kts` — `release` buildType (`isMinifyEnabled = true`,
  `isShrinkResources = true`), signing config read from `keystore.properties`
  with a debug-signing fallback for headless/CI builds, and the version
  (`versionCode` / `versionName` — that file is the single source of truth;
  bump it per release as described in step 3 below).
- `app/proguard-rules.pro` — R8 keep rules for kotlinx.serialization, ONNX
  Runtime (JNI), OkHttp/Okio, ML Kit / CameraX, and coroutines. **Do not weaken
  these without re-verifying on a device** (see the runtime caveat below).

Everything below requires credentials/secrets that are **not** in the repo: the
upload keystore and a Google Play Console account.

> Build environment used in this repo:
> `JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=<sdk> ./gradlew ...`
> (AGP 8.5.2 / Kotlin 2.0.21 / compileSdk 34 / minSdk 28).

---

## 1. Generate the upload keystore (one time, keep it safe forever)

Google Play uses **App Signing**: you upload an AAB signed with your *upload*
key; Google re-signs with the *app signing* key it manages. You must keep the
upload key — losing it requires a Play-side key reset. Store it outside the repo
(a password manager / secure vault), never in git.

```bash
keytool -genkeypair \
  -v \
  -keystore claude-relay-upload.jks \
  -alias claude-relay-upload \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -storetype JKS
```

`keytool` prompts for the store password, key password, and a distinguished
name (CN/OU/O/L/ST/C). Record the alias and both passwords — they go into
`keystore.properties` below.

`*.jks` and `*.keystore` are gitignored. Keep the file out of the repo tree
entirely (the `storeFile` path in `keystore.properties` can be absolute).

## 2. Create `keystore.properties` (gitignored, never committed)

Create `ClaudeRelayAndroid/keystore.properties` (the Android project root, next
to `settings.gradle.kts`). This file is in `.gitignore`. Template:

```properties
storeFile=/absolute/path/to/claude-relay-upload.jks
storePassword=<store password>
keyAlias=claude-relay-upload
keyPassword=<key password>
```

`app/build.gradle.kts` detects this file (`rootProject.file("keystore.properties")`):
- **present** → the `release` buildType signs with this upload key (Play-eligible).
- **absent** → the `release` buildType falls back to **debug** signing so
  `./gradlew :app:assembleRelease` still builds (headless/CI). A debug-signed
  artifact is **not** uploadable to Play — it only verifies R8 + keep rules link.

## 2b. CI signing — the APK on the GitHub Releases page

Every `vX.Y.Z` tag runs `.github/workflows/release.yml`, whose `build-android`
job assembles `:app:assembleRelease` and publishes it as
`coderelay-vX.Y.Z-android.apk` under the release's **Android client** section.
That build has no `keystore.properties`, so by default it is **debug-signed
with the runner's throwaway key** — and Android refuses to install an APK over
an app whose signer differs, so a phone running a locally built APK cannot
update to it (it must uninstall first).

To have CI sign with a stable key, add four repository secrets; the job writes
`keystore.properties` from them and asserts the result is not debug-signed:

```bash
gh secret set ANDROID_KEYSTORE_B64      < <(base64 -w0 /path/to/key.jks)   # macOS: base64 -i key.jks
gh secret set ANDROID_KEYSTORE_PASSWORD --body '<store password>'
gh secret set ANDROID_KEY_ALIAS         --body '<alias>'
gh secret set ANDROID_KEY_PASSWORD      --body '<key password>'
```

Which key to upload:

- **The upload key from §1** — the right long-term answer, and the one that
  keeps Play and GitHub installs mutually updatable. Phones that currently run
  a debug-signed build must uninstall once when switching.
- **The dev Mac's debug key** — `~/.android/debug.keystore`, store/key
  password `android`, alias `androiddebugkey`. This is what the `android-v*`
  pre-releases to date were signed with, so uploading it lets existing phones
  update from the GitHub APK with no uninstall. It is a debug key: fine for the
  test-build channel, never Play-eligible.

Without the secrets the release still publishes; its Android section carries a
note saying the APK is debug-signed.

## 3. Bump the version (each release)

In `app/build.gradle.kts > android.defaultConfig`:
- `versionCode` — **must strictly increase** for every Play upload (integer).
- `versionName` — human-readable (e.g. `"0.3-m4"`, then `"1.0"` at GA).

The "About" screen reads these via `BuildConfig` (`buildConfig = true`).

## 4. Build the release AAB (App Bundle — what Play wants)

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=<sdk> \
  ./gradlew :app:bundleRelease
```

Output: `app/build/outputs/bundle/release/app-release.aab`.

**Save the R8 mapping file** for crash de-obfuscation:
`app/build/outputs/mapping/release/mapping.txt`. Upload it to Play Console
(per release) so stack traces in Android vitals are readable.

(`:app:assembleRelease` produces an APK instead — useful for local install/test,
not the Play upload format.)

### Verify before upload (device — see runtime caveat)
Because R8 strips at build time but stripping bugs only surface at **runtime**,
install the *minified* release build on a real device and exercise:
- saved-server load + add/edit (exercises `ConnectionConfig` JSON round-trip),
- the session list (exercises `SessionInfo` deserialization),
- on-device speech (exercises the ONNX Runtime JNI bridge),
- the QR scanner (exercises ML Kit barcode + CameraX).
A serializer/native symbol stripped by a too-aggressive rule would crash here,
not at build time.

## 5. Google Play Console — first publish

1. **Create the app**: Play Console → Create app → name "ClaudeRelay", default
   language, app/free, accept declarations. Package name `relay.app` is fixed by
   `applicationId` and is permanent once published.
2. **App signing**: opt into **Play App Signing** (default). Upload the AAB; Play
   generates/holds the app signing key, you keep the upload key from step 1.
3. **Store listing**: short + full description, app icon (512×512), feature
   graphic (1024×500), and **screenshots**:
   - Phone: at least 2 (16:9 or 9:16, 320–3840 px per side).
   - 7" + 10" tablet: at least 1 each (required to surface the app as
     tablet-/large-screen-ready, which this app is via the NavigationSplitView
     analog).
4. **Content rating** questionnaire and **target audience** (not directed at
   children).

## 6. Data safety form (Play's privacy declaration)

Play requires a Data Safety section (the Play analog of iOS privacy nutrition
labels). For this app:

| Data type | Collected? | Shared? | Notes |
|-----------|-----------|---------|-------|
| **Microphone / audio** | Used on-device only | No | On-device speech-to-text (WhisperKit/ONNX). Audio is **not** uploaded or transmitted off-device; it is processed locally and discarded. |
| **Camera / images** | Used on-device only | No | QR-code scanning to add a server (ML Kit barcode, on-device). No images stored or sent. |
| Personal/financial/location/contacts | None | — | Not collected. |

Declare:
- **No data sold.**
- **No data shared** with third parties.
- **On-device processing** for mic + camera (no off-device transmission).
- Data is **not** required to be collected (the app's core is a terminal relay;
  speech + QR are optional conveniences).

> Note: unlike iOS, Play has **no** `ITSAppUsesNonExemptEncryption` /
> export-compliance toggle in the AAB metadata. The privacy story is captured
> entirely by the Data Safety form above (mic on-device, camera on-device, no
> sharing/selling). TLS (`wss://`) usage needs no special encryption export
> declaration for Play.

## 7. Permissions rationale

The app requests:
- `RECORD_AUDIO` — on-device voice input (push-to-talk + continuous listening).
  Requested at first use; the app is fully usable by typing if denied.
- `CAMERA` — scanning a QR code to add a server connection. Requested at first
  use of the QR scanner; servers can always be added manually if denied.

Both are user-initiated, on-device only, and have graceful no-permission paths.
Document this in the listing and in the in-app permission rationale prompts.

## 8. Release tracks (promote progressively)

Mirror the iOS TestFlight cadence (internal → external testers → release):

1. **Internal testing** — instant, up to 100 testers. Smoke-test the minified
   build on real hardware (run the step-4 device checklist here first).
2. **Closed testing** — invite a wider tester list (email lists / Google
   Groups). Gather feedback; Play may require a closed-testing period before a
   first production release for new personal developer accounts.
3. **Open testing** (optional) — public opt-in beta.
4. **Production** — staged rollout (e.g. 10% → 50% → 100%) so you can halt on a
   crash spike in Android vitals (this is where the uploaded `mapping.txt` pays
   off).

Each track upload is just another `bundleRelease` AAB with a higher
`versionCode`; the mapping file changes per build, so upload the matching one.

---

## Runtime-correctness caveat (R8 keep rules)

A successful `./gradlew :app:assembleRelease` only proves the keep rules are
**syntactically valid** and R8 can shrink the whole dependency graph. It does
**not** prove R8 left every needed serializer/native symbol in place — a wrong
or missing keep rule manifests as a **runtime** `SerializationException`,
`ClassNotFoundException`, or `UnsatisfiedLinkError`, only when the minified APK
runs on a device. Always run the **step-4 device checklist** on a minified build
before promoting a track. This verification is device-deferred and is **not**
covered by the headless build gate.
