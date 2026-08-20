import AppKit
import SwiftUI

/// A read-only text surface for debug payloads.
///
/// Prompts and provider responses routinely run to tens of thousands of characters.
/// SwiftUI's `Text` lays all of that out eagerly, which is why the payloads used to be
/// truncated before they were shown. `NSTextView` scrolls its own contents, so the whole
/// payload can be presented in a fixed amount of screen space, with selection and the
/// standard find bar (⌘F) that reading a large payload actually needs.
struct DebugPayloadTextView: NSViewRepresentable {
    let text: String
    let accessibilityLabel: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 11, height: 11)
        textView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textView.textColor = NSColor(PlainwordTheme.textPrimary)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Wrap rather than scroll sideways: reading a payload in two axes is miserable.
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityRoleDescription("debug payload")
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.scroll(.zero)
        }
        textView.setAccessibilityLabel(accessibilityLabel)
    }
}

/// A titled payload with its size, a copy action, and a scrolling body.
struct DebugPayloadPane: View {
    let title: String
    let text: String
    var maxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(PlainwordFont.ui(12, weight: .bold))
                Text(sizeLabel)
                    .font(PlainwordFont.mono(10))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                Spacer(minLength: 8)
                DebugCopyButton(text: text, subject: title)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)

            if text.isEmpty {
                Text("Nothing was recorded for this section.")
                    .font(PlainwordFont.ui(11))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 22)
            } else {
                DebugPayloadTextView(text: text, accessibilityLabel: title)
                    .frame(height: maxHeight)
            }
        }
        .plainwordCard(cornerRadius: 10, fill: PlainwordTheme.raisedSurface)
    }

    private var sizeLabel: String {
        let count = text.count
        return "\(count.formatted()) " + (count == 1 ? "char" : "chars")
    }
}

/// Copies the complete text and says so, so the click has a visible result.
struct DebugCopyButton: View {
    let text: String
    let subject: String

    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                didCopy = false
            }
        } label: {
            Text(didCopy ? "\u{2713} Copied" : "Copy")
        }
        .buttonStyle(PlainwordButtonStyle(.quiet))
        .disabled(text.isEmpty)
        .animation(PlainwordMotion.content, value: didCopy)
        .help("Copy the complete \(subject.lowercased()) to the clipboard")
        .accessibilityLabel(didCopy ? "Copied \(subject)" : "Copy \(subject)")
    }
}
