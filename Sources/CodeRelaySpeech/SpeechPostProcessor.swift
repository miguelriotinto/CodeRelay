import Foundation

/// Unified post-processing for raw Whisper transcripts. Called by both
/// `OnDeviceSpeechEngine` (push-to-talk) and `ContinuousListeningEngine`
/// so `smartCleanupEnabled` / `promptEnhancementEnabled` behave identically
/// across modes.
///
/// Never throws — failures fall back to passthrough or cleanup.
@MainActor
public final class SpeechPostProcessor {

    private let cleaner: any TextCleaning
    private let enhancer: any CloudEnhancing

    public init(cleaner: any TextCleaning, enhancer: any CloudEnhancing) {
        self.cleaner = cleaner
        self.enhancer = enhancer
    }

    public func process(
        _ rawText: String,
        options: SpeechProcessingOptions
    ) async -> ProcessedText {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount < 2 || TranscriberError.isSilenceHallucination(trimmed) {
            return .empty
        }

        let wantsEnhancement =
            options.promptEnhancementEnabled && !options.bedrockBearerToken.isEmpty

        if wantsEnhancement {
            do {
                let enhanced = try await enhancer.enhance(
                    trimmed,
                    bearerToken: options.bedrockBearerToken,
                    region: options.bedrockRegion
                )
                return .enhanced(enhanced)
            } catch let err as EnhancerError {
                if case .refused = err {
                    return .refused(original: trimmed)
                }
                // Fall through to cleanup/passthrough for other EnhancerError cases
                if options.smartCleanupEnabled {
                    return await runCleanup(trimmed)
                }
                return .passthrough(trimmed)
            } catch {
                if options.smartCleanupEnabled {
                    return await runCleanup(trimmed)
                }
                return .passthrough(trimmed)
            }
        }

        if options.smartCleanupEnabled {
            return await runCleanup(trimmed)
        }
        return .passthrough(trimmed)
    }

    private func runCleanup(_ text: String) async -> ProcessedText {
        do {
            let cleaned = try await cleaner.clean(text)
            return .cleaned(cleaned)
        } catch {
            return .passthrough(text)
        }
    }
}
