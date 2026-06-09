# ============================================================================
# ClaudeRelay Android — R8 / ProGuard keep rules (release buildType)
# ============================================================================
#
# CRITICAL: wrong/missing rules here = a RUNTIME crash in release (not a build
# error). The release buildType runs R8 with isMinifyEnabled + isShrinkResources
# (see app/build.gradle.kts). Everything that is reflection- or JNI-based must be
# kept explicitly — R8 cannot see those usages in the static call graph.
#
# Scope notes:
# - Most of our libraries (OkHttp, Okio, kotlinx-coroutines, CameraX, ML Kit)
#   ship their own *consumer* ProGuard rules inside their AARs, which AGP merges
#   automatically. The rules below are belt-and-suspenders for the parts that
#   matter to us (reflection/JNI) plus `-dontwarn` for known-benign references.
# - kotlinx.serialization is the one library where the app MUST carry the keep
#   rules itself: the generated `$$serializer` classes and the `serializer()`
#   companions are resolved reflectively at runtime.
#
# RUNTIME-CORRECTNESS CAVEAT: a build-time `assembleRelease` only proves these
# rules are syntactically valid and R8 can shrink the full graph. Proving R8 did
# not strip a needed serializer/native symbol requires RUNNING the minified APK
# on a device — that verification is DEVICE-DEFERRED.

# Keep annotations on members (RuntimeVisible*Annotations) so reflection — and
# kotlinx.serialization's @Serializable/@SerialName lookups — see them.
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod

# ----------------------------------------------------------------------------
# kotlinx.serialization
# ----------------------------------------------------------------------------
# Canonical rules adapted from the kotlinx-serialization consumer ProGuard file
# (Kotlin/kotlinx.serialization `rules/common.pro`). They keep:
#   1. the serialization runtime,
#   2. every @Serializable type's synthetic Companion (carries serializer()),
#   3. every generated `$$serializer` object + its INSTANCE + serialize/
#      deserialize/childSerializers methods,
#   4. enums marked @Serializable (values()/valueOf reflection).

# Keep the serialization runtime + its annotations.
-keepclassmembers @kotlinx.serialization.Serializable class ** {
    static **$* *;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class kotlinx.serialization.** { *; }
-keepclassmembers class kotlinx.serialization.** { *; }
-dontwarn kotlinx.serialization.**

# For every class annotated @Serializable, keep its synthetic Companion (which
# exposes `serializer()`) and the generated `$$serializer` nested object.
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$Companion Companion;
}
-if @kotlinx.serialization.Serializable class ** {
    static **$* *;
}
-keepclassmembers class <2>$<3> {
    kotlinx.serialization.KSerializer serializer(...);
}
-if @kotlinx.serialization.Serializable class **
-keep class <1>$$serializer {
    *;
}

# ----------------------------------------------------------------------------
# relay.protocol — our @Serializable wire models + custom KSerializer objects
# ----------------------------------------------------------------------------
# These are serialized by name/reflection (ConnectionConfig, SessionInfo,
# SessionNamingTheme) and via hand-written KSerializer objects (UuidSerializer,
# SessionStateSerializer, ActivityStateSerializer, ReferenceDateDoubleSerializer).
# SavedConnectionStore persists ConnectionConfig as JSON, so stripping any of
# these silently breaks saved-server load + the session list. The generic
# kotlinx rules above already cover the @Serializable types; this block is an
# explicit safety net for the whole package (models, enums, custom serializers).
-keep class relay.protocol.** { *; }
-keepclassmembers class relay.protocol.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}

# ----------------------------------------------------------------------------
# ONNX Runtime (com.microsoft.onnxruntime → ai.onnxruntime API + JNI)
# ----------------------------------------------------------------------------
# Backs the Silero VAD + Smart-Turn detectors (:speech). The Java API classes
# under ai.onnxruntime.** are bound to native libonnxruntime*.so via JNI; the
# native side looks up Java fields/methods by name, so obfuscation breaks the
# bridge. Keep the API surface and ALL native-method signatures everywhere.
-keep class ai.onnxruntime.** { *; }
-keep class com.microsoft.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
-dontwarn com.microsoft.onnxruntime.**
# JNI: never rename a class that declares native methods, and keep the methods.
-keepclasseswithmembernames class * {
    native <methods>;
}

# ----------------------------------------------------------------------------
# ConnectBot termlib (org.connectbot.terminal.** → libvterm via JNI)
# ----------------------------------------------------------------------------
# The real VT100/xterm terminal engine (:feature-workspace TerminalHost). Its
# native lib `libjni_cb_term.so` calls BOTH directions across JNI:
#   - TerminalNative declares the `external fun native*` methods (the generic
#     `native <methods>` keep above already protects those), AND
#   - the native layer invokes the TerminalCallbacks implementation
#     (the internal TerminalEmulatorImpl) BY METHOD NAME — damage / moveCursor /
#     onKeyboardInput / pushScrollbackLine / setTermProp / bell / etc. R8 cannot
#     see those native→Java callbacks in the static graph, so without an explicit
#     keep it would rename or strip them and the bridge would fail at runtime
#     (terminal creation → UnsatisfiedLinkError / blank screen / crash). The JNI
#     also reads back data classes by field (ScreenCell, CellRun, CursorPosition,
#     TermRect). Keep the whole package's members. termlib also @Parcelize-s some
#     types (kotlin-parcelize); their reflective CREATOR is covered here too.
-keep class org.connectbot.terminal.** { *; }
-keepclassmembers class org.connectbot.terminal.** { *; }
-dontwarn org.connectbot.terminal.**

# ----------------------------------------------------------------------------
# OkHttp / Okio
# ----------------------------------------------------------------------------
# OkHttp + Okio ship consumer rules in their AARs/JARs (AGP merges them). These
# `-dontwarn` lines silence the optional/platform references OkHttp guards with
# reflection (Conscrypt, BouncyCastle, OpenJSSE, Animal-Sniffer annotations)
# which R8 would otherwise flag as missing.
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn javax.annotation.**
-dontwarn org.codehaus.mojo.animal_sniffer.*

# ----------------------------------------------------------------------------
# ML Kit barcode scanning + CameraX (QR scan — device-deferred feature)
# ----------------------------------------------------------------------------
# ML Kit loads model/detector implementations reflectively and via dynamic
# feature delegation; it ships consumer rules, but keep its surface defensively
# since a stripped detector class surfaces only at QR-scan time on-device.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**
# CameraX ships consumer rules; silence optional references only.
-dontwarn androidx.camera.**

# ----------------------------------------------------------------------------
# kotlinx.coroutines
# ----------------------------------------------------------------------------
# Coroutines ships consumer rules (keeps the internal ServiceLoader factories +
# the volatile field machinery). Only `-dontwarn` is needed here for the JDK
# `java.lang.invoke`/internal references R8 may not resolve.
-dontwarn kotlinx.coroutines.**
-dontwarn java.lang.management.**

# ----------------------------------------------------------------------------
# AndroidX / Compose / general
# ----------------------------------------------------------------------------
# Compose + AndroidX ship consumer rules. Keep enums' valueOf/values (used by
# kotlinx.serialization enum handling and assorted reflective lookups).
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
# Keep Kotlin metadata so reflective Kotlin features (incl. serialization) work.
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
