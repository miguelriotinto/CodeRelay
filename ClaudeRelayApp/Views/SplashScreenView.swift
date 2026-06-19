import SwiftUI

struct SplashScreenView: View {
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var finished = false

    let onComplete: () -> Void

    // Matches the sRGB background of AppIcon/SplashLogo (black). Keep in sync
    // with the icon PNG — if the icon ever changes, resample and update here.
    private let brandColor = Color.black

    var body: some View {
        ZStack {
            brandColor.ignoresSafeArea()

            VStack(spacing: 20) {
                // SplashLogo is a white CR glyph on a transparent background (no
                // opaque box), so nothing dark is revealed as the splash fades out
                // over the lighter ServerListView beneath it.
                Image("SplashLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                Text("Code Relay")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(textOpacity)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(textOpacity)
            }
        }
        .opacity(finished ? 0 : 1)
        .task {
            await animateSequence()
        }
    }

    // MARK: - Animation Sequence

    @MainActor
    private func animateSequence() async {
        // Phase 1: Logo scales up + fades in (0 → 0.8s)
        withAnimation(.spring(duration: 0.8, bounce: 0.3)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }
        try? await Task.sleep(for: .seconds(0.6))

        // Phase 2: Text fades in with slight delay (0.6 → 1.1s)
        withAnimation(.easeOut(duration: 0.5)) {
            textOpacity = 1.0
        }
        try? await Task.sleep(for: .seconds(1.4))

        // Phase 3: Fade out everything (2.0 → 2.7s)
        withAnimation(.easeInOut(duration: 0.7)) {
            finished = true
        }
        try? await Task.sleep(for: .seconds(0.7))

        onComplete()
    }
}
