import SwiftUI

@MainActor
final class CoveLaunchPresentation: ObservableObject {
    @Published private(set) var isVisible: Bool
    private(set) var dismissalReason: String?

    init(isVisible: Bool = true) { self.isVisible = isVisible }

    func dismiss(reason: String) {
        guard isVisible else { return }
        dismissalReason = reason
        isVisible = false
    }
}

/// A cold-launch overlay for Cove. It owns no app state and performs no work other
/// than its short, cancellable animation. The caller decides when it is inserted.
struct CoveLaunchHugAnimation<Destination: View>: View {
    enum MotionMode: Sendable {
        case system
        case full
        case reduced
    }

    let replayID: Int
    var playbackRate: Double = 1
    var motionMode: MotionMode = .system
    var onFinished: () -> Void = {}
    @ViewBuilder var destination: () -> Destination

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var dotProgress: CGFloat = 0
    @State private var dotVisible: CGFloat = 0
    @State private var embrace: CGFloat = 0
    @State private var settle: CGFloat = 0
    @State private var reveal: CGFloat = 0
    @State private var logoDeparture: CGFloat = 0

    private var reduceMotion: Bool {
        switch motionMode {
        case .system: systemReduceMotion
        case .full: false
        case .reduced: true
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                destination()
                    .opacity(reveal)
                    .scaleEffect(0.992 + 0.008 * reveal)
                    .accessibilityHidden(reveal < 0.5)

                launchSurface(in: proxy.size)
                    .opacity(1 - reveal)

                if logoDeparture < 1 {
                    mark(size: 174)
                        .scaleEffect(1 - 0.76 * logoDeparture)
                        .offset(y: -max(0, proxy.size.height / 2 - 91) * logoDeparture)
                        .opacity(1 - max(0, (logoDeparture - 0.76) / 0.24))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(launchPink.opacity(1 - reveal).ignoresSafeArea())
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(reveal < 1)
        .task(id: replayID) { await play() }
    }

    private func launchSurface(in size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.25, green: 0.13, blue: 0.20), Color(red: 0.34, green: 0.17, blue: 0.25)]
                    : [Color(red: 0.91, green: 0.48, blue: 0.64), Color(red: 0.86, green: 0.38, blue: 0.57)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                RadialGradient(
                    colors: [Color.white.opacity(colorScheme == .dark ? 0.035 : 0.10), .clear],
                    center: UnitPoint(x: 0.42, y: 0.38),
                    startRadius: 2,
                    endRadius: min(size.width, size.height) * 0.58
                )
            }

            // The glow travels through the right-hand opening rather than orbiting.
            Circle()
                .fill(cream)
                .frame(width: 22, height: 22)
                .shadow(color: cream.opacity(0.38), radius: 10)
                .scaleEffect(0.72 + 0.28 * sin(.pi * dotProgress))
                .opacity(dotVisible)
                .offset(
                    x: 144 - 112 * dotProgress,
                    y: -2 + 8 * sin(.pi * dotProgress)
                )
        }
    }

    private func mark(size: CGFloat) -> some View {
        ZStack {
            CoveCShape(embrace: embrace - 0.22 * settle)
                .fill(cream)
                .frame(width: size, height: size)
        }
        .scaleEffect(1 - 0.018 * embrace + 0.007 * settle)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 14, y: 6)
    }

    @MainActor
    private func reset() {
        dotProgress = 0
        dotVisible = 0
        embrace = 0
        settle = 0
        reveal = 0
        logoDeparture = 0
    }

    private func delay(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds / max(0.25, playbackRate)))
    }

    @MainActor
    private func play() async {
        reset()
        do {
            if reduceMotion {
                try await delay(0.10)
                withAnimation(.easeOut(duration: 0.28 / max(0.25, playbackRate))) {
                    reveal = 1
                    logoDeparture = 1
                }
                try await delay(0.30)
            } else {
                try await delay(0.14)
                withAnimation(.easeOut(duration: 0.08 / playbackRate)) {
                    dotVisible = 1
                }
                withAnimation(.timingCurve(0.22, 0.72, 0.26, 1, duration: 0.50 / playbackRate)) {
                    dotProgress = 1
                }
                try await delay(0.43)
                withAnimation(.spring(response: 0.30 / playbackRate, dampingFraction: 0.82)) {
                    embrace = 1
                }
                try await delay(0.25)
                withAnimation(.easeOut(duration: 0.12 / playbackRate)) {
                    dotVisible = 0
                }
                withAnimation(.spring(response: 0.34 / playbackRate, dampingFraction: 0.86)) {
                    embrace = 0
                    settle = 1
                }
                try await delay(0.31)
                withAnimation(.timingCurve(0.20, 0.72, 0.25, 1, duration: 0.42 / playbackRate)) {
                    reveal = 1
                    logoDeparture = 1
                }
                try await delay(0.46)
            }
            guard !Task.isCancelled else { return }
            onFinished()
        } catch is CancellationError {
            // Replays and removal cancel the structured task; no delayed work leaks.
        } catch {
            // Task.sleep has no other expected failure mode.
        }
    }

    private var cream: Color {
        colorScheme == .dark
            ? Color(red: 1.00, green: 0.95, blue: 0.90)
            : Color(red: 1.00, green: 0.97, blue: 0.91)
    }

    private var launchPink: Color {
        colorScheme == .dark
            ? Color(red: 0.25, green: 0.13, blue: 0.20)
            : Color(red: 0.89, green: 0.43, blue: 0.61)
    }
}

/// A hand-tuned approximation of the supplied app-icon silhouette. Unlike a font
/// glyph, its uneven, rounded arms preserve the icon's soft open-embrace character.
private struct CoveCShape: Shape {
    var embrace: CGFloat = 0

    var animatableData: CGFloat {
        get { embrace }
        set { embrace = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 1024
        let sy = rect.height / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * sx, y: y * sy) }

        var path = Path()
        path.move(to: p(779, 371 + 13 * embrace))
        path.addCurve(to: p(527, 283), control1: p(718, 307 + 10 * embrace), control2: p(626, 272))
        path.addCurve(to: p(350, 506), control1: p(416, 314), control2: p(350, 411))
        path.addCurve(to: p(522, 699), control1: p(350, 611), control2: p(427, 699))
        path.addCurve(to: p(747, 581 - 13 * embrace), control1: p(616, 699), control2: p(665, 626 - 8 * embrace))
        path.addCurve(to: p(858, 590 - 10 * embrace), control1: p(794, 557 - 10 * embrace), control2: p(841, 565 - 10 * embrace))
        path.addCurve(to: p(849, 690), control1: p(875, 617), control2: p(865, 655))
        path.addCurve(to: p(514, 861), control1: p(785, 815), control2: p(656, 864))
        path.addCurve(to: p(165, 516), control1: p(318, 857), control2: p(165, 720))
        path.addCurve(to: p(535, 165), control1: p(165, 321), control2: p(321, 165))
        path.addCurve(to: p(803, 271), control1: p(651, 165), control2: p(750, 205))
        path.addCurve(to: p(779, 371), control1: p(831, 306), control2: p(819, 360))
        path.closeSubpath()
        return path
    }
}
