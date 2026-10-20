import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class ApplicationAccessibilitySupportTests: XCTestCase {
    private typealias Application = ApplicationAccessibilitySupport.Application
    private typealias Outcome = ApplicationAccessibilitySupport.Outcome

    private final nonisolated class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Application] = []
        private var mainThreadReads: [Bool] = []
        private var timeouts = 0
        let outcomes: [Outcome]
        let firstGate: DispatchSemaphore?

        init(outcomes: [Outcome] = [.ready], firstGate: DispatchSemaphore? = nil) {
            self.outcomes = outcomes
            self.firstGate = firstGate
        }

        var applications: [Application] {
            self.lock.withLock { self.recorded }
        }

        var ranOnMain: [Bool] {
            self.lock.withLock { self.mainThreadReads }
        }

        var timedOut: Bool {
            self.lock.withLock { self.timeouts > 0 }
        }

        func prepare(_ application: Application) -> Outcome {
            let index = self.lock.withLock {
                let index = self.recorded.count
                self.recorded.append(application)
                self.mainThreadReads.append(Thread.isMainThread)
                return index
            }
            if index == 0, let gate = self.firstGate, gate.wait(timeout: .now() + 3) != .success {
                self.lock.withLock { self.timeouts += 1 }
                return .cancelled
            }
            return self.outcomes[min(index, self.outcomes.count - 1)]
        }
    }

    @MainActor
    private final class Environment {
        var application: Application?
        var trusted = true

        init(_ application: Application?) {
            self.application = application
        }
    }

    private final class SuspendedQueue {
        let queue = DispatchQueue(label: "test.fluid.accessibility-queued")
        private var suspended = true

        init() {
            self.queue.suspend()
        }

        func resume() {
            guard self.suspended else { return }
            self.suspended = false
            self.queue.resume()
        }
    }

    private let editor = Application(pid: 100, bundleIdentifier: "test.editor", launchDate: Date(timeIntervalSince1970: 1000))
    private let other = Application(pid: 200, bundleIdentifier: "test.other", launchDate: Date(timeIntervalSince1970: 2000))

    private func service(
        _ environment: Environment,
        requests: Requests,
        queue: DispatchQueue = DispatchQueue(label: "test.fluid.accessibility")
    ) -> ApplicationAccessibilitySupport {
        ApplicationAccessibilitySupport(
            ownPID: 999,
            isTrusted: { environment.trusted },
            currentApplication: { environment.application },
            queue: queue,
            prepare: requests.prepare
        )
    }

    @discardableResult
    private func waitForRequests(_ requests: Requests, count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while requests.applications.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(requests.applications.count, count)
        return requests.applications.count == count
    }

    func testPreparationRunsOffMainAndSuccessfulResultIsReused() async {
        let environment = Environment(self.editor)
        let requests = Requests()
        let sut = self.service(environment, requests: requests)
        let first = await sut.prepareForCapture()
        let second = await sut.prepareForCapture()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(requests.applications, [self.editor])
        XCTAssertEqual(requests.ranOnMain, [false])
    }

    func testCaptureJoinsPrewarmWhileMainActorRemainsResponsive() async {
        let environment = Environment(self.editor)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let requests = Requests(firstGate: gate)
        let sut = self.service(environment, requests: requests)
        sut.prewarm()
        guard await self.waitForRequests(requests, count: 1) else { return }
        let capture = Task { await sut.prepareForCapture() }
        await Task.yield()
        XCTAssertEqual(environment.application, self.editor, "Main actor remains available while AX work waits")
        XCTAssertEqual(requests.applications, [self.editor])
        gate.signal()
        let result = await capture.value
        XCTAssertTrue(result)
        XCTAssertFalse(requests.timedOut)
        XCTAssertEqual(requests.applications, [self.editor])
    }

    func testTransientPreparationFailureDoesNotAuthorizeFocusAndIsRetried() async {
        let environment = Environment(self.editor)
        let requests = Requests(outcomes: [.failed(-25_212), .ready])
        let sut = self.service(environment, requests: requests)
        let first = await sut.prepareForCapture()
        let retry = await sut.prepareForCapture()
        XCTAssertTrue(first, "A failed preparation leaves ordinary focus policy responsible for refusal")
        XCTAssertTrue(retry)
        XCTAssertEqual(requests.applications, [self.editor, self.editor])
    }

    func testUnsupportedAppStillUsesOrdinaryFocusCapture() async {
        let requests = Requests(outcomes: [.unsupported])
        let sut = self.service(Environment(self.editor), requests: requests)
        let result = await sut.prepareForCapture()
        XCTAssertTrue(result)
        XCTAssertEqual(requests.applications, [self.editor])
    }

    func testCancelledPreparationRefusesCaptureEvenWhenApplicationIsUnchanged() async {
        let requests = Requests(outcomes: [.cancelled])
        let sut = self.service(Environment(self.editor), requests: requests)
        let result = await sut.prepareForCapture()
        XCTAssertFalse(result)
        XCTAssertEqual(requests.applications, [self.editor])
    }

    func testUnsafeOrUnavailableApplicationsNeverReceivePreparation() async {
        let environment = Environment(nil)
        let requests = Requests()
        let sut = self.service(environment, requests: requests)
        let invalid: [Application?] = [
            nil,
            .init(pid: 0, bundleIdentifier: "test.invalid", launchDate: self.editor.launchDate),
            .init(pid: -1, bundleIdentifier: "test.invalid", launchDate: self.editor.launchDate),
            .init(pid: 999, bundleIdentifier: "test.self", launchDate: self.editor.launchDate),
            .init(pid: 100, bundleIdentifier: "", launchDate: self.editor.launchDate),
        ]
        for application in invalid {
            environment.application = application
            sut.prewarm()
            let result = await sut.prepareForCapture()
            XCTAssertTrue(result)
        }
        environment.application = self.editor
        environment.trusted = false
        sut.prewarm()
        let untrusted = await sut.prepareForCapture()
        XCTAssertTrue(untrusted)
        XCTAssertTrue(requests.applications.isEmpty)
    }

    func testRelaunchAndProcessIdentityChangesRequireFreshPreparation() async {
        let environment = Environment(self.editor)
        let requests = Requests()
        let sut = self.service(environment, requests: requests)
        let identities = [
            self.editor,
            Application(pid: 101, bundleIdentifier: self.editor.bundleIdentifier, launchDate: self.other.launchDate),
            Application(pid: 101, bundleIdentifier: self.editor.bundleIdentifier, launchDate: self.editor.launchDate),
            Application(pid: 101, bundleIdentifier: self.other.bundleIdentifier, launchDate: self.editor.launchDate),
        ]
        for application in identities {
            environment.application = application
            let result = await sut.prepareForCapture()
            XCTAssertTrue(result)
        }
        XCTAssertEqual(requests.applications, identities)
    }

    func testOnlyCurrentApplicationReadinessIsRetained() async {
        let environment = Environment(self.editor)
        let requests = Requests()
        let sut = self.service(environment, requests: requests)
        for application in [self.editor, self.other, self.editor] {
            environment.application = application
            let result = await sut.prepareForCapture()
            XCTAssertTrue(result)
        }
        XCTAssertEqual(requests.applications, [self.editor, self.other, self.editor])
    }

    func testPrewarmingUnavailableTargetInvalidatesPreviousReadiness() async {
        let environment = Environment(self.editor)
        let requests = Requests()
        let sut = self.service(environment, requests: requests)
        _ = await sut.prepareForCapture()
        environment.application = nil
        sut.prewarm()
        environment.application = self.editor
        _ = await sut.prepareForCapture()
        XCTAssertEqual(requests.applications, [self.editor, self.editor])
    }

    func testSwitchBeforeQueuedWorkStartsSkipsOldApplication() async {
        let queue = SuspendedQueue()
        defer { queue.resume() }
        let environment = Environment(self.editor)
        let requests = Requests()
        let sut = self.service(environment, requests: requests, queue: queue.queue)
        sut.prewarm()
        environment.application = self.other
        sut.prewarm()
        queue.resume()
        let result = await sut.prepareForCapture()
        XCTAssertTrue(result)
        XCTAssertEqual(requests.applications, [self.other])
    }

    func testStopCancelsQueuedPreparationAndCapture() async {
        let queue = SuspendedQueue()
        defer { queue.resume() }
        let requests = Requests()
        let sut = self.service(Environment(self.editor), requests: requests, queue: queue.queue)
        sut.prewarm()
        var captureDidBegin = false
        let capture = Task {
            await sut.prepareForCapture(isCaptureCurrent: {
                captureDidBegin = true
                return true
            })
        }
        let deadline = Date().addingTimeInterval(1)
        while !captureDidBegin, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(captureDidBegin)
        sut.stop()
        queue.resume()
        let result = await capture.value
        XCTAssertFalse(result)
        XCTAssertTrue(requests.applications.isEmpty)
    }

    func testOldCompletionCannotEraseNewApplicationPreparation() async {
        let environment = Environment(self.editor)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let requests = Requests(firstGate: gate)
        let sut = self.service(environment, requests: requests)
        let oldCapture = Task { await sut.prepareForCapture() }
        guard await self.waitForRequests(requests, count: 1) else { return }
        environment.application = self.other
        sut.prewarm()
        let newCapture = Task { await sut.prepareForCapture() }
        gate.signal()
        let oldResult = await oldCapture.value
        let newResult = await newCapture.value
        let cachedResult = await sut.prepareForCapture()
        XCTAssertFalse(oldResult)
        XCTAssertTrue(newResult)
        XCTAssertTrue(cachedResult)
        XCTAssertEqual(requests.applications, [self.editor, self.other])
        XCTAssertFalse(requests.timedOut)
    }

    func testCallerCancellationDuringPreparationRefusesCapture() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let requests = Requests(firstGate: gate)
        let sut = self.service(Environment(self.editor), requests: requests)
        let capture = Task { await sut.prepareForCapture() }
        guard await self.waitForRequests(requests, count: 1) else { return }
        capture.cancel()
        gate.signal()
        let result = await capture.value
        XCTAssertFalse(result)
        XCTAssertFalse(requests.timedOut)
    }

    func testAlreadyCancelledCallerDoesNotBeginPreparation() async {
        let requests = Requests()
        let sut = self.service(Environment(self.editor), requests: requests)
        let capture = Task { await sut.prepareForCapture() }
        capture.cancel()
        let result = await capture.value
        XCTAssertFalse(result)
        XCTAssertTrue(requests.applications.isEmpty)
    }

    func testInvalidCaptureLifecycleDoesNotBeginPreparation() async {
        let requests = Requests()
        let sut = self.service(Environment(self.editor), requests: requests)
        let result = await sut.prepareForCapture(isCaptureCurrent: { false })
        XCTAssertFalse(result)
        XCTAssertTrue(requests.applications.isEmpty)
    }

    func testCaptureLifecycleEndingDuringPreparationRefusesCapture() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let requests = Requests(firstGate: gate)
        let sut = self.service(Environment(self.editor), requests: requests)
        var isCurrent = true
        let capture = Task { await sut.prepareForCapture(isCaptureCurrent: { isCurrent }) }
        guard await self.waitForRequests(requests, count: 1) else { return }
        isCurrent = false
        gate.signal()
        let result = await capture.value
        XCTAssertFalse(result)
        XCTAssertFalse(requests.timedOut)
    }

    func testStopDuringCachedPreparationCannotPermitCaptureAfterStop() async {
        let requests = Requests()
        let sut = self.service(Environment(self.editor), requests: requests)
        _ = await sut.prepareForCapture()
        var stopped = false
        var scheduledStop = false
        let result = await sut.prepareForCapture(isCaptureCurrent: {
            if !scheduledStop {
                scheduledStop = true
                Task { @MainActor in
                    sut.stop()
                    stopped = true
                }
            }
            return true
        })
        XCTAssertFalse(stopped && result, "A cache-hit await must not authorize capture after stop() invalidates it")
    }
}
