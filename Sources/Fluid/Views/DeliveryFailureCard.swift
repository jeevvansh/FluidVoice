import SwiftUI

/// Overlay card shown when a transcript could not be delivered. Copy is the
/// single primary action; the card dismisses itself after `autoDismissDelay`.
struct DeliveryFailureCard: View {
    let presentationID: UUID
    let title: String
    let detail: String?
    let transcript: String
    let fontSize: CGFloat
    let compact: Bool
    let maxWidth: CGFloat
    let onDismiss: () -> Void
    var copyToClipboard: (String) -> Bool = { ClipboardService.copyToClipboard($0) }
    var copyDismissDelay: TimeInterval = 1.1

    static let autoDismissDelay: TimeInterval = 10

    @State private var didCopy = false
    @State private var autoDismissWorkItem: DispatchWorkItem?
    @State private var copyDismissWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: self.compact ? 0 : 10) {
            HStack(alignment: .top, spacing: 10) {
                self.glyph
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title)
                        .font(.fluidSystem(size: self.fontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail {
                        Text(detail)
                            .font(.fluidSystem(size: max(self.fontSize - 2, 10), weight: .regular))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(self.compact ? 1 : 2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: !self.compact)
                    }
                }
                Spacer(minLength: 6)
                if self.compact {
                    self.copyButton(fullWidth: false)
                }
                self.closeButton
            }
            if !self.compact {
                self.copyButton(fullWidth: true)
            }
        }
        .frame(maxWidth: self.maxWidth, alignment: .leading)
        .onAppear(perform: self.scheduleAutoDismiss)
        .onDisappear(perform: self.cancelDismissal)
        .onChange(of: self.presentationID) { _, _ in
            self.didCopy = false
            self.scheduleAutoDismiss()
        }
    }

    private var glyph: some View {
        Image(systemName: "text.cursor")
            .font(.fluidSystem(size: max(self.fontSize - 1, 10), weight: .semibold))
            .foregroundStyle(Color.orange.opacity(0.95))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.orange.opacity(0.16)))
            .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button(action: self.dismiss) {
            Image(systemName: "xmark")
                .font(.fluidSystem(size: max(self.fontSize - 3, 9), weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }

    private func copyButton(fullWidth: Bool) -> some View {
        Button(action: self.copy) {
            HStack(spacing: 6) {
                Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                    .font(.fluidSystem(size: max(self.fontSize - 2, 10), weight: .semibold))
                Text(self.didCopy ? "Copied" : "Copy transcript")
                    .font(.fluidSystem(size: max(self.fontSize - 1, 10), weight: .semibold))
            }
            .foregroundStyle(self.didCopy ? Color.black.opacity(0.85) : Color.white.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 30)
            .background(Capsule().fill(self.didCopy ? Color.white.opacity(0.92) : Color.white.opacity(0.13)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy transcript")
    }

    private func copy() {
        self.cancelDismissal()
        let copied = self.copyToClipboard(self.transcript)
        withAnimation(.easeOut(duration: 0.18)) { self.didCopy = copied }
        guard copied else {
            self.scheduleAutoDismiss()
            return
        }
        let workItem = DispatchWorkItem { self.dismiss() }
        self.copyDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + self.copyDismissDelay, execute: workItem)
    }

    private func dismiss() {
        self.cancelDismissal()
        self.onDismiss()
    }

    private func scheduleAutoDismiss() {
        self.cancelDismissal()
        let workItem = DispatchWorkItem { self.onDismiss() }
        self.autoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissDelay, execute: workItem)
    }

    private func cancelDismissal() {
        self.autoDismissWorkItem?.cancel()
        self.autoDismissWorkItem = nil
        self.copyDismissWorkItem?.cancel()
        self.copyDismissWorkItem = nil
    }
}
