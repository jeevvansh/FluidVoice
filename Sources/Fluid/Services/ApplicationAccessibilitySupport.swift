import AppKit
import ApplicationServices

/// Prepares an app's accessibility tree before normal focus capture.
@MainActor
final class ApplicationAccessibilitySupport {
    nonisolated struct Application: Equatable, Sendable {
        let pid: pid_t
        let bundleIdentifier: String
        let launchDate: Date
    }

    nonisolated enum Outcome: Equatable, Sendable {
        case ready
        case unsupported
        case failed(Int32)
        case cancelled
    }

    static let shared = ApplicationAccessibilitySupport()

    private let ownPID: pid_t
    private let isTrusted: @MainActor () -> Bool
    private let currentApplication: @MainActor () -> Application?
    private let prepare: @Sendable (Application) -> Outcome
    private let queue: DispatchQueue
    private var observer: NSObjectProtocol?
    private var readyApplication: Application?
    private var pending: Request?

    private struct Request {
        let id: UUID
        let application: Application
        let cancellation: Cancellation
        let task: Task<Outcome, Never>
    }

    private final nonisolated class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            self.lock.withLock { self.cancelled }
        }

        func cancel() {
            self.lock.withLock { self.cancelled = true }
        }
    }

    init(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        currentApplication: @escaping @MainActor () -> Application? = { ApplicationAccessibilitySupport.frontmostApplication() },
        queue: DispatchQueue = DispatchQueue(label: "com.FluidApp.Fluid.accessibility-preparation", qos: .userInitiated),
        prepare: @escaping @Sendable (Application) -> Outcome = { ApplicationAccessibilitySupport.prepareAccessibility(for: $0) }
    ) {
        self.ownPID = ownPID
        self.isTrusted = isTrusted
        self.currentApplication = currentApplication
        self.queue = queue
        self.prepare = prepare
    }

    func start() {
        guard self.observer == nil else { return }
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prewarm() }
        }
        self.prewarm()
    }

    func stop() {
        if let observer = self.observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        self.invalidate()
    }

    func prewarm() {
        guard let application = self.eligibleApplication() else {
            self.invalidate()
            return
        }
        guard self.readyApplication != application else { return }
        _ = self.preparation(for: application)
    }

    /// False means capture was cancelled or the foreground app changed while preparing.
    func prepareForCapture(isCaptureCurrent: @MainActor () -> Bool = { true }) async -> Bool {
        guard !Task.isCancelled, isCaptureCurrent() else { return false }
        guard let application = self.eligibleApplication() else {
            self.invalidate()
            return true
        }
        if self.readyApplication == application {
            return true
        }
        let outcome = await self.preparation(for: application).value
        guard !Task.isCancelled, isCaptureCurrent(), outcome != .cancelled else { return false }
        return self.currentApplication() == application
    }

    private func eligibleApplication() -> Application? {
        guard self.isTrusted(), let application = self.currentApplication(),
              application.pid > 0, application.pid != self.ownPID,
              !application.bundleIdentifier.isEmpty,
              application.bundleIdentifier != "com.FluidApp.app",
              application.bundleIdentifier != "com.FluidApp.app.debug" else { return nil }
        return application
    }

    private func invalidate() {
        self.pending?.cancellation.cancel()
        self.pending?.task.cancel()
        self.pending = nil
        self.readyApplication = nil
    }

    private func preparation(for application: Application) -> Task<Outcome, Never> {
        if let pending = self.pending, pending.application == application {
            return pending.task
        }
        self.invalidate()
        let id = UUID()
        let cancellation = Cancellation()
        let queue = self.queue
        let prepare = self.prepare
        let task = Task { @MainActor [weak self] in
            guard let self else { return Outcome.cancelled }
            defer {
                if self.pending?.id == id {
                    self.pending = nil
                }
            }
            guard !cancellation.isCancelled,
                  self.eligibleApplication() == application else { return Outcome.cancelled }
            let outcome = await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: Outcome.cancelled)
                        return
                    }
                    let result = prepare(application)
                    continuation.resume(returning: cancellation.isCancelled ? .cancelled : result)
                }
            }
            guard self.pending?.id == id else { return Outcome.cancelled }
            guard !cancellation.isCancelled, self.eligibleApplication() == application else { return Outcome.cancelled }
            if outcome == .ready {
                self.readyApplication = application
            } else if case let .failed(code) = outcome {
                DebugLogger.shared.warning("AX_SUPPORT preparation failed pid=\(application.pid) axError=\(code)", source: "ApplicationAccessibilitySupport")
            }
            return outcome
        }
        self.pending = Request(id: id, application: application, cancellation: cancellation, task: task)
        return task
    }

    private static func frontmostApplication() -> Application? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              let launchDate = app.launchDate else { return nil }
        return Application(pid: app.processIdentifier, bundleIdentifier: bundleIdentifier, launchDate: launchDate)
    }

    private nonisolated static func prepareAccessibility(for application: Application) -> Outcome {
        guard AXIsProcessTrusted() else { return .failed(AXError.apiDisabled.rawValue) }
        let appElement = AXUIElementCreateApplication(application.pid)
        let timeoutResult = AXUIElementSetMessagingTimeout(appElement, 0.2)
        guard timeoutResult == .success else { return .failed(timeoutResult.rawValue) }
        // Electron documents this app-level request for third-party assistive software.
        // It exposes the tree; the ordinary capture and delivery checks still choose the field.
        let result = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .success {
            DebugLogger.shared.info("AX_SUPPORT enabled pid=\(application.pid) bundle=\(application.bundleIdentifier)", source: "ApplicationAccessibilitySupport")
            return .ready
        }
        if result == .attributeUnsupported || result == .notImplemented {
            return .unsupported
        }
        return .failed(result.rawValue)
    }
}
