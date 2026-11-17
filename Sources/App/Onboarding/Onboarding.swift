import AppKit
import CircularityEngine
import SwiftUI

/// What the welcome and tutorial ask of the rest of the app.
protocol OnboardingHost: AnyObject {
    func onboardingFinished(launchAtLogin: Bool, finderShortcutTurnedOn: Bool, startTutorial: Bool)
    func onboardingPracticeWheel()
    func tutorialClose()
}

// MARK: - Welcome (first launch)

final class OnboardingModel: ObservableObject {
    weak var host: OnboardingHost?
    let settings: SettingsStore
    @Published var step = 0
    @Published var launchAtLogin: Bool
    @Published var notifications: Bool
    @Published var finderShortcut = ServiceShortcut.isInstalled
    private let finderShortcutAtStart = ServiceShortcut.isInstalled

    init(settings: SettingsStore) {
        self.settings = settings
        notifications = settings.value(SettingsKeys.notifyEnabled)
        // First run: suggest on. Shown again later: show what is true now.
        launchAtLogin = settings.value(SettingsKeys.onboardingCompleted) ? (LoginItem.isEnabled || LoginItem.needsApproval) : true
    }

    var finderShortcutTurnedOn: Bool { finderShortcut && !finderShortcutAtStart }

    var accent: Color { Color(nsColor: Appearance.accentNS(settings)) }

    func setNotifications(_ on: Bool) {
        guard on else {
            notifications = false
            settings.set(false, for: SettingsKeys.notifyEnabled)
            return
        }
        Notifier.shared.requestPermission { [weak self] granted in
            self?.notifications = granted
            self?.settings.set(granted, for: SettingsKeys.notifyEnabled)
        }
    }

    func setFinderShortcut(_ on: Bool) {
        if on { _ = ServiceShortcut.install() } else { ServiceShortcut.uninstall() }
        finderShortcut = ServiceShortcut.isInstalled
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let a = model.accent
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch model.step {
                case 0: welcome(a)
                case 1: privacy(a)
                default: setup(a)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule().fill(i == model.step ? a : Color.white.opacity(0.18)).frame(width: i == model.step ? 18 : 6, height: 6)
                }
                Spacer()
                if model.step > 0 {
                    HaloButton(title: "Back", accent: a) { model.step -= 1 }
                }
                if model.step < 2 {
                    HaloButton(title: "Continue", primary: true, accent: a) { model.step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    HaloButton(title: "Skip the tutorial", accent: a) {
                        model.host?.onboardingFinished(launchAtLogin: model.launchAtLogin,
                                                       finderShortcutTurnedOn: model.finderShortcutTurnedOn, startTutorial: false)
                    }
                    HaloButton(title: "Show me how", primary: true, accent: a) {
                        model.host?.onboardingFinished(launchAtLogin: model.launchAtLogin,
                                                       finderShortcutTurnedOn: model.finderShortcutTurnedOn, startTutorial: true)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 560, height: 470)
        .background(Halo.background)
        .animation(.easeOut(duration: 0.2), value: model.step)
    }

    private func welcome(_ a: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            GlyphImage(size: 44, color: NSColor(a))
            Text("CIRCULARITY").font(Halo.mono(30, .heavy)).tracking(1.6).foregroundStyle(a)
            Text("Convert files without opening anything.").font(Halo.rounded(17, .semibold)).foregroundStyle(Halo.text)
            VStack(alignment: .leading, spacing: 12) {
                stepLine("1", "Start dragging a file — from Finder, the desktop, anywhere.", a)
                stepLine("2", "Tap Shift (or shake the pointer). A wheel of formats appears.", a)
                stepLine("3", "Let go on a format. The new file appears next to the original.", a)
            }
            Text("The icon in the menu bar opens a panel with presets, recent results and ⌘K.")
                .font(Halo.rounded(12)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func privacy(_ a: Color) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WHAT IT DOESN'T TOUCH").font(Halo.mono(20, .heavy)).tracking(1.2).foregroundStyle(a)
            Text("\(AppIdentity.name) needs no special permission, and macOS won't ask for one.")
                .font(Halo.rounded(14, .semibold)).foregroundStyle(Halo.text)
            VStack(alignment: .leading, spacing: 10) {
                privacyLine("keyboard", "No Accessibility or Input Monitoring — it never sees what you type.")
                privacyLine("rectangle.dashed", "No Screen Recording — it never reads what's on screen.")
                privacyLine("network.slash", "No network — conversions happen on this Mac and nothing is uploaded.")
                privacyLine("folder", "Only the files you hand it. Originals are never changed.")
                privacyLine("doc.on.clipboard", "The clipboard only when you press ⌃⌥V.")
            }
        }
    }

    private func setup(_ a: Color) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A FEW CHOICES").font(Halo.mono(20, .heavy)).tracking(1.2).foregroundStyle(a)
            Text("All of these can be changed later in Settings.").font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
            VStack(alignment: .leading, spacing: 14) {
                ToggleRow(title: "Open at login", detail: "So the wheel is ready whenever you drag a file.", isOn: $model.launchAtLogin, accent: a)
                ToggleRow(title: "Notify me when conversions finish", detail: "macOS will ask once.",
                          isOn: Binding(get: { model.notifications }, set: { model.setNotifications($0) }), accent: a)
                ToggleRow(title: "⌃⌥C converts the Finder selection",
                          detail: "Select files in Finder and press ⌃⌥C. Finder picks it up after it restarts.",
                          isOn: Binding(get: { model.finderShortcut }, set: { model.setFinderShortcut($0) }), accent: a)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Halo.card))
        }
    }

    private func stepLine(_ n: String, _ text: String, _ a: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).font(Halo.mono(14, .heavy)).foregroundStyle(a.readableText)
                .frame(width: 24, height: 24).background(Circle().fill(a))
            Text(text).font(Halo.rounded(14)).foregroundStyle(Halo.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func privacyLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Halo.secondary).frame(width: 20)
            Text(text).font(Halo.rounded(13)).foregroundStyle(Halo.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Interactive tutorial

/// Follows what the user actually does: a real drag, the real wheel, a real
/// conversion of a practice picture (never their own files).
final class TutorialModel: ObservableObject {
    enum Step: Int, CaseIterable { case drag, choose, done, more, finished }

    weak var host: OnboardingHost?
    let settings: SettingsStore
    @Published var step = Step.drag
    @Published var resultLine = ""
    let practice: URL?

    init(settings: SettingsStore) {
        self.settings = settings
        practice = TutorialModel.freshPractice()
    }

    var accent: Color { Color(nsColor: Appearance.accentNS(settings)) }
    var triggerName: String { settings.value(SettingsKeys.triggerKey).capitalized }

    /// A new copy each time, in its own folder, so results are easy to find and to throw away.
    static func freshPractice() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Tutorial", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Practice photo.png")
        guard let image = samplePicture(size: 640, scale: 1),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    func wheelShown() {
        if step == .drag { step = .choose }
    }

    /// A job finished; only results made from the practice picture count.
    func jobFinished(_ result: JobResult) {
        guard let practice, result.outcomes.contains(where: { $0.inputs.contains { $0.standardizedFileURL == practice.standardizedFileURL } }),
              let output = result.outputs.first else { return }
        resultLine = "\(output.lastPathComponent) · \(Bytes.text(result.bytesOut))"
        if step == .choose || step == .drag { step = .done } else if step == .more { step = .finished }
    }
}

struct TutorialView: View {
    @ObservedObject var model: TutorialModel

    var body: some View {
        let a = model.accent
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TUTORIAL").font(Halo.mono(13, .heavy)).tracking(1).foregroundStyle(Halo.secondary)
                Spacer()
                Text("\(min(model.step.rawValue + 1, 4)) of 4").font(Halo.mono(11, .bold)).foregroundStyle(Halo.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                if let url = model.practice, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(a.opacity(model.step == .drag || model.step == .more ? 0.9 : 0.2), lineWidth: 2))
                        .shadow(color: a.opacity(model.step == .drag ? 0.5 : 0), radius: 12)
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .help("Drag this picture")
                        .accessibilityLabel("Practice photo. Drag it to try the wheel.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(Halo.mono(20, .heavy)).tracking(0.8).foregroundStyle(a).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(Halo.rounded(13)).foregroundStyle(Halo.text).fixedSize(horizontal: false, vertical: true)
                    if !model.resultLine.isEmpty && (model.step == .done || model.step == .finished) {
                        Text(model.resultLine).font(Halo.mono(12, .bold)).foregroundStyle(Halo.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if model.step == .drag || model.step == .choose {
                    Text("Stuck? The wheel also opens without dragging:").font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
                    HaloButton(title: "Open it", accent: a) { model.host?.onboardingPracticeWheel() }
                }
                Spacer()
                switch model.step {
                case .done:
                    HaloButton(title: "Next: More", primary: true, accent: a) { model.step = .more }
                case .finished:
                    HaloButton(title: "Show the file", accent: a) {
                        if let dir = model.practice?.deletingLastPathComponent() { NSWorkspace.shared.open(dir) }
                    }
                    HaloButton(title: "Finish", primary: true, accent: a) { model.host?.tutorialClose() }
                        .keyboardShortcut(.defaultAction)
                default:
                    HaloButton(title: model.step == .more ? "Skip" : "Close", accent: a) {
                        if model.step == .more { model.step = .finished } else { model.host?.tutorialClose() }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Halo.background)
        .animation(.easeOut(duration: 0.2), value: model.step)
    }

    private var title: String {
        switch model.step {
        case .drag: "Drag the picture"
        case .choose: "Now choose a format"
        case .done: "Done!"
        case .more: "Try More"
        case .finished: "That's it"
        }
    }

    private var detail: String {
        let key = model.triggerName
        switch model.step {
        case .drag: return "Press on the picture and start dragging — keep the button down — then tap \(key). The wheel opens around the pointer."
        case .choose: return "Still holding the button, move onto JPG and let go. Letting go in the middle cancels."
        case .done: return "A JPG was made next to the practice picture. Your own files work the same way, from anywhere."
        case .more: return "Drag the picture again, tap \(key), and rest on ••• MORE. More formats fan out — let go on one, like TIFF."
        case .finished: return "You're set. The menu bar icon has the panel; Settings has themes, presets and shortcuts. The practice files are in a temporary folder and clear themselves."
        }
    }
}
