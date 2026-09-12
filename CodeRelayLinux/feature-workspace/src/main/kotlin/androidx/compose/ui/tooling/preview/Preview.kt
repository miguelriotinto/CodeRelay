package androidx.compose.ui.tooling.preview

/**
 * Desktop stand-in for AndroidX's `@Preview`.
 *
 * Compose Multiplatform ships an equivalent, but under
 * `org.jetbrains.compose.ui.tooling.preview` — a different package, so the
 * shared UI files that carry `@Preview` would not compile against it without
 * editing their imports. Declaring the annotation here instead lets
 * `ActivityDot`, `ConnectionQualityDot` and `SessionTabs` compile **unchanged**,
 * which is the whole point of sharing them.
 *
 * The annotation is metadata only: it marks preview functions for tooling and
 * has no runtime behaviour, so an empty declaration is fully equivalent for a
 * build. It is retained at source level because nothing reads it at runtime.
 *
 * Only the no-argument form is declared, matching every use in the shared
 * sources. If a shared file ever adds `@Preview(showBackground = true)` this
 * will fail to compile — which is the desired outcome: better a build error
 * than a silently ignored parameter.
 */
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.ANNOTATION_CLASS)
annotation class Preview
