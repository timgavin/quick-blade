import SwiftUI

struct ContentView: View {
    // Brand red (#FF4047) — same Display P3 components as the AppIcon.icon glyph fill
    private static let brandRed = Color(.displayP3, red: 1.0, green: 0.25098, blue: 0.27843)

    // nil = still checking, .some(nil) = undeterminable, .some(.some(x)) = known
    @State private var status: ExtensionStatus?? = nil
    @State private var titlebarInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                // The compiled app icon, rounded-rect shape and all — matches
                // what the user sees in the Dock and in onboarding panels.
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)

                Text("Quick Blade")
                    .font(.title.bold())

                Text("Quick Look for Blade")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 18) {
                statusHeadline
                    .frame(maxWidth: .infinity)

                instruction(
                    icon: "text.document",
                    text: "Select a .blade.php file in Finder and press the Space bar to preview it."
                )

                if status != .some(.some(.enabled)) {
                    instruction(
                        icon: "gearshape",
                        text: "No preview? Turn on Quick Blade in System Settings \u{203A} General \u{203A} Login Items & Extensions \u{203A} Quick Look."
                    )
                }
            }
            .padding(.horizontal, 36)

            Button {
                // Launch-once helper: the window is the whole app, so
                // dismissing it means quitting rather than lingering in the Dock.
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Continue")
                    .fontWeight(.semibold)
            }
            .buttonStyle(PillButtonStyle(fill: Self.brandRed))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue")
            .padding(.top, 40)
            .padding(.bottom, 36)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        // The hidden titlebar still reserves a top safe area. Ignoring it lets the
        // header sit flush with the window top, but the window's fitting height
        // still includes the inset, which reappears as dead space at the bottom —
        // the negative padding cancels it using the measured titlebar height.
        .padding(.bottom, -titlebarInset)
        .ignoresSafeArea(.container, edges: .top)
        .background(TitlebarInsetReader { titlebarInset = $0 })
        .task {
            let result = await Task.detached { ExtensionStatus.check() }.value
            status = .some(result)
        }
    }

    @ViewBuilder
    private var statusHeadline: some View {
        switch status {
        case .some(.some(.enabled)):
            Label {
                Text("Extension is active.").font(.headline)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.green).font(.system(size: 10))
            }
        case .some(.some(.disabled)):
            Label {
                Text("Extension is turned off.").font(.headline)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.orange).font(.system(size: 10))
            }
        default:
            // Checking, or undeterminable in the sandbox — show nothing rather than guess.
            EmptyView()
        }
    }

    private func instruction(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Self.brandRed)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Fixed-size capsule button — the bordered styles add their own padding, which
/// makes exact outer dimensions impossible to hit.
private struct PillButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 200, height: 30)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Reports the window's titlebar height (frame minus contentLayoutRect) once the
/// view lands in a window. NSView is the only reliable way to reach the NSWindow
/// from inside a SwiftUI Window scene.
private struct TitlebarInsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> InsetView {
        let view = InsetView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: InsetView, context: Context) {}

    final class InsetView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onChange?(window.frame.height - window.contentLayoutRect.height)
        }
    }
}

#Preview {
    ContentView()
}
