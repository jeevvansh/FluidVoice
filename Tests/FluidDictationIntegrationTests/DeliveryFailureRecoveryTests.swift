import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import Vision
import XCTest

/// Exercises the real SwiftUI presentations in a reused host, without the
/// app lifecycle, system clipboard, or input events in another application.
@MainActor
final class DeliveryFailureRecoveryTests: XCTestCase {
    private final class Clipboard {
        var text = ""
        var succeeds = true
        var writes: [String] = []

        func copy(_ text: String) -> Bool {
            self.writes.append(text)
            guard self.succeeds else { return false }
            self.text = text
            return true
        }
    }

    @MainActor
    private final class Host {
        private final class TestWindow: NSWindow {
            override var canBecomeKey: Bool {
                true
            }

            override var canBecomeMain: Bool {
                true
            }
        }

        private final class TestView: NSHostingView<AnyView> {
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
                true
            }
        }

        let view: NSHostingView<AnyView>
        let window: NSWindow
        let copyAtRight: Bool
        let compact: Bool

        init(_ content: some View, copyAtRight: Bool = false, compact: Bool = false) {
            _ = NSApplication.shared
            self.copyAtRight = copyAtRight
            self.compact = compact
            self.view = TestView(rootView: AnyView(content.background(Color.black).transaction { $0.disablesAnimations = true }))
            self.window = TestWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 440, height: 160),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            self.window.isReleasedWhenClosed = false
            self.window.contentView = self.view
            self.window.makeKeyAndOrderFront(nil)
            self.settle()
        }

        func replace(_ content: some View) {
            self.view.rootView = AnyView(content.background(Color.black).transaction { $0.disablesAnimations = true })
            self.settle()
        }

        func settle(_ duration: TimeInterval = 0.05) {
            self.window.setContentSize(self.view.fittingSize)
            self.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(duration))
        }

        private var copyPoint: NSPoint {
            if self.compact {
                return NSPoint(x: self.view.bounds.width - 95, y: self.view.bounds.midY)
            }
            let fromBottom: CGFloat = self.copyAtRight ? 26 : 15
            return NSPoint(
                x: self.copyAtRight ? self.view.bounds.width - 70 : self.view.bounds.midX,
                y: self.view.isFlipped ? self.view.bounds.height - fromBottom : fromBottom
            )
        }

        func pressCopy() throws {
            let location = self.view.convert(self.copyPoint, to: nil)
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: self.window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: pressure
                ))
                self.window.sendEvent(event)
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            self.settle()
        }

        /// Read pixels rendered by this fixture, not the screen or another app.
        func copyFeedback() async throws -> String {
            self.settle(0.25)
            self.view.displayIfNeeded()
            let bitmap = try XCTUnwrap(self.view.bitmapImageRepForCachingDisplay(in: self.view.bounds))
            self.view.cacheDisplay(in: self.view.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let labels = try await Task.detached {
                let context = try XCTUnwrap(CGContext(
                    data: nil,
                    width: image.width * 3,
                    height: image.height * 3,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                let enlarged = try XCTUnwrap(context.makeImage())
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.customWords = ["Copy transcript", "Copied"]
                try VNImageRequestHandler(cgImage: enlarged).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }.value
            // Vision can include the leading copy/checkmark glyph in its line.
            let label = try XCTUnwrap(labels.first { $0.hasSuffix("Copied") || $0.hasSuffix("Copy transcript") }, "Rendered text: \(labels)")
            return label.hasSuffix("Copied") ? "Copied" : "Copy transcript"
        }

        func close() {
            self.window.contentView = nil
            self.window.orderOut(nil)
            self.window.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func overlay(
        _ transcript: String,
        id: UUID = UUID(),
        clipboard: Clipboard,
        onCopied: @escaping () -> Void = {}
    ) -> some View {
        DeliveryFailureOverlayPresentation(
            presentationID: id,
            kind: .noEditableTarget,
            transcript: transcript,
            displayDuration: 10,
            startedAt: Date(),
            onCopied: onCopied,
            onDismiss: {},
            copyToClipboard: clipboard.copy
        )
    }

    private func card(
        _ transcript: String,
        id: UUID = UUID(),
        clipboard: Clipboard,
        compact: Bool = false,
        copyDismissDelay: TimeInterval = 1.1,
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        DeliveryFailureCard(
            presentationID: id,
            title: "Text wasn't inserted",
            detail: nil,
            transcript: transcript,
            fontSize: 14,
            compact: compact,
            maxWidth: 440,
            onDismiss: onDismiss,
            copyToClipboard: clipboard.copy,
            copyDismissDelay: copyDismissDelay
        )
    }

    func testFreshRecoveryPresentationsCopyProvidedTranscript() throws {
        for transient in [false, true] {
            let clipboard = Clipboard()
            let content = transient
                ? AnyView(self.overlay("transcript", clipboard: clipboard))
                : AnyView(self.card("transcript", clipboard: clipboard))
            let host = Host(content, copyAtRight: transient)
            defer { host.close() }
            try host.pressCopy()
            XCTAssertEqual(clipboard.text, "transcript")
            XCTAssertEqual(clipboard.writes, ["transcript"])
        }
    }

    func testEveryNewRecoveryPresentationResetsCopiedFeedback() async throws {
        for transient in [false, true] {
            for repeatsTranscript in [false, true] {
                let clipboard = Clipboard()
                func content(_ text: String) -> AnyView {
                    transient
                        ? AnyView(self.overlay(text, clipboard: clipboard))
                        : AnyView(self.card(text, clipboard: clipboard))
                }
                let host = Host(content("first transcript"), copyAtRight: transient)
                defer { host.close() }
                let initialFeedback = try await host.copyFeedback()
                XCTAssertEqual(initialFeedback, "Copy transcript")
                try host.pressCopy()
                let copiedFeedback = try await host.copyFeedback()
                XCTAssertEqual(copiedFeedback, "Copied")
                host.replace(content(repeatsTranscript ? "first transcript" : "second transcript"))
                let replacementFeedback = try await host.copyFeedback()
                XCTAssertEqual(replacementFeedback, "Copy transcript")
            }
        }
    }

    func testTransientReplacementCopiesLatestTranscript() throws {
        let clipboard = Clipboard()
        let host = Host(self.overlay("first transcript", clipboard: clipboard), copyAtRight: true)
        defer { host.close() }
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "first transcript")

        host.replace(self.overlay("second transcript", clipboard: clipboard))
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "second transcript")
        XCTAssertEqual(clipboard.writes, ["first transcript", "second transcript"])
    }

    func testTransientRepeatedTextIsANewCopyablePresentation() throws {
        let clipboard = Clipboard()
        let host = Host(self.overlay("same transcript", clipboard: clipboard), copyAtRight: true)
        defer { host.close() }
        try host.pressCopy()
        host.replace(self.overlay("same transcript", clipboard: clipboard))
        try host.pressCopy()
        XCTAssertEqual(clipboard.writes, ["same transcript", "same transcript"])
    }

    func testTransientFailedCopyStaysAvailableAndCanRetry() throws {
        let clipboard = Clipboard()
        clipboard.succeeds = false
        var copied = 0
        let host = Host(self.overlay("transcript", clipboard: clipboard) { copied += 1 }, copyAtRight: true)
        defer { host.close() }
        try host.pressCopy()
        XCTAssertEqual(copied, 0)
        XCTAssertEqual(clipboard.writes, ["transcript"])
        clipboard.succeeds = true
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "transcript")
        XCTAssertEqual(copied, 1)
    }

    func testTransientCopyAgainRestoresTranscriptAfterClipboardReplacement() throws {
        let clipboard = Clipboard()
        let host = Host(self.overlay("transcript", clipboard: clipboard), copyAtRight: true)
        defer { host.close() }
        try host.pressCopy()
        clipboard.text = "copied elsewhere"
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "transcript")
        XCTAssertEqual(clipboard.writes.count, 2)
    }

    func testTransientFailedRecopyDoesNotReportAnotherSuccessAndCanRetry() throws {
        let clipboard = Clipboard()
        var copied = 0
        let host = Host(self.overlay("transcript", clipboard: clipboard) { copied += 1 }, copyAtRight: true)
        defer { host.close() }
        try host.pressCopy()
        XCTAssertEqual(copied, 1)
        clipboard.text = "copied elsewhere"
        clipboard.succeeds = false
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "copied elsewhere")
        XCTAssertEqual(copied, 1)
        clipboard.succeeds = true
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "transcript")
        XCTAssertEqual(copied, 2)
        XCTAssertEqual(clipboard.writes.count, 3)
    }

    func testInlineReplacementCopiesLatestTranscript() throws {
        let clipboard = Clipboard()
        let host = Host(self.card("first transcript", clipboard: clipboard))
        defer { host.close() }
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "first transcript")
        host.replace(self.card("second transcript", clipboard: clipboard))
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "second transcript")
    }

    func testInlineRepeatedTextIsANewCopyablePresentation() throws {
        let clipboard = Clipboard()
        let host = Host(self.card("same transcript", clipboard: clipboard))
        defer { host.close() }
        try host.pressCopy()
        host.replace(self.card("same transcript", clipboard: clipboard))
        try host.pressCopy()
        XCTAssertEqual(clipboard.writes, ["same transcript", "same transcript"])
    }

    func testInlineFailedCopyDoesNotDismissAndCanRetry() throws {
        let clipboard = Clipboard()
        clipboard.succeeds = false
        var dismissals = 0
        let host = Host(self.card("transcript", clipboard: clipboard, copyDismissDelay: 0.1) { dismissals += 1 })
        defer { host.close() }
        try host.pressCopy()
        host.settle(0.2)
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(clipboard.writes, ["transcript"])
        clipboard.succeeds = true
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "transcript")
        host.settle(0.2)
        XCTAssertEqual(dismissals, 1)
    }

    func testInlineCopyAgainRestoresTranscriptAfterClipboardReplacement() throws {
        let clipboard = Clipboard()
        let host = Host(self.card("transcript", clipboard: clipboard))
        defer { host.close() }
        try host.pressCopy()
        clipboard.text = "copied elsewhere"
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "transcript")
        XCTAssertEqual(clipboard.writes.count, 2)
    }

    func testInlineFailedRecopyCancelsSuccessDismissalAndCanRetry() throws {
        let clipboard = Clipboard()
        var dismissals = 0
        let host = Host(self.card("transcript", clipboard: clipboard, copyDismissDelay: 0.25) { dismissals += 1 })
        defer { host.close() }
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "transcript")
        clipboard.text = "copied elsewhere"
        clipboard.succeeds = false
        try host.pressCopy()
        host.settle(0.3)
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(clipboard.text, "copied elsewhere")
        clipboard.succeeds = true
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "transcript")
        host.settle(0.3)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(clipboard.writes.count, 3)
    }

    func testCompactInlineCardCopiesLatestTranscriptAfterReplacement() throws {
        let clipboard = Clipboard()
        let host = Host(self.card("first", clipboard: clipboard, compact: true), compact: true)
        defer { host.close() }
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "first")
        host.replace(self.card("second", clipboard: clipboard, compact: true))
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "second")
        XCTAssertEqual(clipboard.writes, ["first", "second"])
    }

    func testOldInlineCopyDismissalCannotDismissNewPresentation() throws {
        let clipboard = Clipboard()
        var dismissed: [String] = []
        let host = Host(self.card("first", clipboard: clipboard, copyDismissDelay: 0.2) { dismissed.append("first") })
        defer { host.close() }
        try host.pressCopy()
        host.replace(self.card("second", clipboard: clipboard, copyDismissDelay: 0.2) { dismissed.append("second") })
        host.settle(0.3)
        XCTAssertTrue(dismissed.isEmpty)
        try host.pressCopy()
        XCTAssertEqual(clipboard.text, "second")
        host.settle(0.3)
        XCTAssertEqual(dismissed, ["second"])
    }

    func testDisappearingInlineCardCancelsCopyDismissal() throws {
        let clipboard = Clipboard()
        var dismissals = 0
        let host = Host(self.card("transcript", clipboard: clipboard, copyDismissDelay: 0.2) { dismissals += 1 })
        defer { host.close() }
        try host.pressCopy()
        host.replace(Color.clear)
        host.settle(0.3)
        XCTAssertEqual(dismissals, 0)
    }
}
