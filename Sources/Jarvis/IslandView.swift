import JarvisCore
import SwiftUI

enum JarvisStyle {
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.23)
    static let rose = Color(red: 1.0, green: 0.30, blue: 0.43)
    static let violet = Color(red: 0.55, green: 0.25, blue: 0.95)
    static let brand = LinearGradient(colors: [amber, rose, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)
}

/// The island's silhouette: flat against the top of the screen, flaring into it at the shoulders,
/// with rounded lower corners, so it looks like it grows out of the display.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        let radius = min(bottomRadius, rect.height - shoulder)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - radius), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The four-point spark from the logo.
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let reach = min(rect.width, rect.height) / 2
        let waist = reach * 0.22
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - reach))
        path.addQuadCurve(to: CGPoint(x: center.x + reach, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + reach), control: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x - reach, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - reach), control: CGPoint(x: center.x - waist, y: center.y - waist))
        path.closeSubpath()
        return path
    }
}

/// Spark that breathes while idle, reacts to your voice, and spins while thinking.
private struct SparkMark: View {
    let phase: IslandPhase
    let level: CGFloat
    var size: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            SparkShape()
                .fill(JarvisStyle.brand)
                .frame(width: size, height: size)
                .scaleEffect(scale(time))
                .rotationEffect(.radians(phase == .thinking ? time * 2.6 : 0))
        }
    }

    private func scale(_ time: Double) -> CGFloat {
        switch phase {
        case .listening: return 1 + level * 0.45
        case .speaking: return 1 + 0.08 * CGFloat(sin(time * 5))
        default: return 1 + 0.04 * CGFloat(sin(time * 1.6))
        }
    }
}

private struct VoiceBars: View {
    /// Nil animates as speech. A value follows the live microphone level.
    let level: CGFloat?
    private let weights: [CGFloat] = [0.55, 0.85, 1, 0.7, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { index in
                    Capsule()
                        .fill(JarvisStyle.brand)
                        .frame(width: 3, height: height(index: index, time: time))
                }
            }
            .frame(height: 20)
        }
    }

    private func height(index: Int, time: Double) -> CGFloat {
        let wobble = CGFloat(0.5 + 0.5 * sin(time * 9 + Double(index) * 1.3))
        let amount = level.map { 0.12 + $0 * (0.5 + 0.5 * wobble) } ?? (0.3 + 0.7 * wobble)
        return max(4, 20 * weights[index] * min(amount, 1))
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(time * 5 - Double(index) * 0.9)))
                }
            }
        }
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: AppSettings

    private static let shoulder: CGFloat = 10

    private var isVisible: Bool {
        model.isOpen || model.phase != .resting || settings.showIslandWhenIdle
    }

    private var width: CGFloat {
        if model.isOpen { return 500 }
        switch model.phase {
        case .resting: return model.hasHardwareNotch ? model.notchWidth : 118
        case .thinking: return max(320, model.notchWidth + 180)
        case .listening: return max(380, model.notchWidth + 180)
        case .speaking, .guiding, .confirming, .message: return max(440, model.notchWidth + 180)
        }
    }

    private var bottomRadius: CGFloat {
        if model.isOpen { return 28 }
        return model.phase == .resting ? 10 : 22
    }

    private var isActive: Bool { model.phase != .resting || model.isOpen }

    var body: some View {
        VStack(spacing: 0) {
            island
                .opacity(isVisible ? 1 : 0)
                .animation(JarvisStyle.spring, value: model.phase)
                .animation(JarvisStyle.spring, value: model.isOpen)
                .animation(JarvisStyle.spring, value: model.reply)
                .animation(JarvisStyle.spring, value: model.activity)
                .animation(JarvisStyle.spring, value: model.transcript)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var island: some View {
        VStack(spacing: 0) {
            if model.isOpen {
                IslandHome(model: model)
                    .transition(.opacity)
            } else {
                header
                phaseBody
            }
        }
        .frame(width: width)
        .clipped()
        .padding(.horizontal, Self.shoulder)
        .background(alignment: .top) { backdrop }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            model.size = size
        }
    }

    private var backdrop: some View {
        let shape = IslandShape(bottomRadius: bottomRadius, shoulder: Self.shoulder)
        return ZStack {
            // A colored glow behind the island that swells with your voice.
            if model.phase == .listening || model.phase == .speaking {
                shape
                    .fill(JarvisStyle.brand)
                    .blur(radius: 18)
                    .opacity(model.phase == .listening ? 0.35 + Double(model.level) * 0.55 : 0.4)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
            shape
                .fill(.black)
                .shadow(color: .black.opacity(isActive ? 0.4 : 0), radius: 20, y: 10)
            shape
                .stroke(.white.opacity(isActive ? 0.09 : 0), lineWidth: 1)
        }
    }

    // MARK: - Compact states

    private var header: some View {
        HStack(spacing: 0) {
            if model.phase == .resting {
                if !model.hasHardwareNotch {
                    Spacer()
                    SparkShape()
                        .fill(JarvisStyle.brand)
                        .frame(width: 13, height: 13)
                    Spacer()
                }
            } else {
                SparkMark(phase: model.phase, level: model.level)
                Spacer(minLength: model.hasHardwareNotch ? model.notchWidth : 8)
                trailingIndicator
            }
        }
        .padding(.horizontal, model.phase == .resting ? 0 : 18)
        .frame(height: model.phase == .resting ? model.topHeight : max(model.topHeight, 38))
    }

    @ViewBuilder private var trailingIndicator: some View {
        switch model.phase {
        case .listening:
            VoiceBars(level: model.level)
        case .thinking:
            ThinkingDots()
        case .speaking:
            VoiceBars(level: nil)
        case .guiding:
            Text("Step \(model.guideStep)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(JarvisStyle.brand, in: Capsule())
        case .confirming:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(JarvisStyle.amber)
        case .message:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(JarvisStyle.amber)
        case .resting:
            EmptyView()
        }
    }

    @ViewBuilder private var phaseBody: some View {
        switch model.phase {
        case .resting:
            EmptyView()
        case .listening:
            bodyText(model.transcript.isEmpty ? "Listening…" : model.transcript, dim: model.transcript.isEmpty)
        case .thinking:
            bodyText(model.progress.isEmpty ? "Looking at your screen…" : model.progress, dim: true)
        case .speaking:
            VStack(alignment: .leading, spacing: 6) {
                activityLine
                replyWithStop
                noticeLine
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .transition(.opacity)
        case .guiding:
            VStack(alignment: .leading, spacing: 6) {
                replyWithStop
                Text("Click the circled spot to continue, or press Esc to stop.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                noticeLine
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .transition(.opacity)
        case .confirming:
            confirmation
        case .message:
            bodyText(model.message, dim: false)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.confirmTitle)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !model.confirmDetail.isEmpty {
                Text(model.confirmDetail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            noticeLine
            HStack(spacing: 8) {
                Button { model.onConfirm(true) } label: {
                    Text("Yes, do it")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { model.onConfirm(false) } label: {
                    Text("No")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Text("Or hold \(model.hotkeySymbols) and say yes or no")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .transition(.opacity)
    }

    private func bodyText(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(dim ? 0.6 : 1))
            .lineLimit(4)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .transition(.opacity)
    }

    private var replyWithStop: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(model.reply)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(5)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.onStop) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Stop (Esc)")
        }
    }

    @ViewBuilder private var activityLine: some View {
        if !model.activity.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: model.activity.hasSuffix("…") ? "arrow.up.forward.app" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text(model.activity)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.7))
            .transition(.opacity)
        }
    }

    @ViewBuilder private var noticeLine: some View {
        if !model.notice.isEmpty {
            Text(model.notice)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(JarvisStyle.amber)
                .lineLimit(2)
        }
    }
}

// MARK: - Open panel

/// Opens when you hover over the island: your conversation and a box to type a question.
private struct IslandHome: View {
    @ObservedObject var model: IslandModel
    @State private var draft = ""
    @State private var chatHeight: CGFloat = 0
    @FocusState private var composerFocused: Bool

    private let suggestions = ["What's on my screen?", "Explain what I'm looking at", "Walk me through this app"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if model.conversation.isEmpty {
                emptyState
            } else {
                conversationList
            }
            composer
        }
        .padding(.horizontal, 18)
        .padding(.top, max(model.topHeight + 8, 14))
        .padding(.bottom, 16)
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            SparkShape()
                .fill(JarvisStyle.brand)
                .frame(width: 18, height: 18)
            Text("Jarvis")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Text("Hold \(model.hotkeySymbols) to talk")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Button(action: model.onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What can I help with?")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            HStack(spacing: 7) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { model.onAsk(suggestion) } label: {
                        Text(suggestion)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var conversationList: some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.conversation.enumerated()), id: \.offset) { index, turn in
                        if !turn.user.hasPrefix("(clicked") {
                            Text(turn.user)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        Text(turn.assistant)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chatHeight = $0 }
            }
            // Fits a short chat, and scrolls once it's taller than this.
            .frame(height: min(chatHeight, 230))
            .onAppear { reader.scrollTo(model.conversation.count - 1, anchor: .bottom) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, prompt: Text("Ask about your screen…").foregroundStyle(.white.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white)
                .focused($composerFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(draft.isEmpty ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(JarvisStyle.brand))
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.white.opacity(0.1), in: Capsule())
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.onAsk(text)
    }
}
