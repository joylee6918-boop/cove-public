import XCTest
@testable import Cove

@MainActor
final class CoveVoiceNoteTests: XCTestCase {
    final class Recording: CoveAudioRecording {
        let url: URL
        var currentTime: TimeInterval = 1.25
        var isMeteringEnabled = false
        var power: Float = -20
        var starts = 0
        var stops = 0
        var succeeds = true
        let bytes = Data(repeating: 0x2a, count: 1024) // Synthetic, not an actual user recording.
        init(url: URL) { self.url = url }
        func record() -> Bool { starts += 1; try? bytes.write(to: url); return succeeds }
        func stop() { stops += 1 }
        func updateMeters() {}
        func averagePower(forChannel channelNumber: Int) -> Float { power }
    }

    func testOriginalAudioNeedsOnlyMicrophoneAndStopsWithoutTranscription() async {
        var recording: Recording?
        var permissions = 0
        let recorder = CoveVoiceRecorder(requestPermission: { permissions += 1; return true }, makeRecorder: { url in
            let value = Recording(url: url); recording = value; return value
        }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(permissions, 1)
        XCTAssertTrue(recording?.isMeteringEnabled == true)
        recorder.endHold()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.preview, recording?.bytes)
        XCTAssertFalse(recorder.isTranscribing)
        XCTAssertEqual(recorder.transcript, "")
        XCTAssertEqual(recorder.duration, 1.25)
        recorder.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording!.url.path))
    }

    func testReleaseDuringPermissionDoesNotRecordAfterApproval() async {
        var permission: CheckedContinuation<Bool, Never>?
        let asked = expectation(description: "microphone permission requested")
        var starts = 0
        let recorder = CoveVoiceRecorder(requestPermission: {
            await withCheckedContinuation { permission = $0; asked.fulfill() }
        }, makeRecorder: { url in starts += 1; return Recording(url: url) }, activateSession: {}, deactivateSession: {})
        let task = Task { await recorder.startFromExplicitTap() }
        await fulfillment(of: [asked], timeout: 1)
        XCTAssertTrue(recorder.isRequestingPermission)
        recorder.endHold()
        permission?.resume(returning: true)
        await task.value
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(recorder.hasDraft)
    }

    func testImmediateReleaseBeforeScheduledPermissionDoesNotPrompt() async {
        var prompts = 0
        let recorder = CoveVoiceRecorder(requestPermission: { prompts += 1; return true }, makeRecorder: { Recording(url: $0) }, activateSession: {}, deactivateSession: {})
        recorder.startFromExplicitAction()
        XCTAssertTrue(recorder.isRequestingPermission)
        recorder.endHold()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(prompts, 0)
        XCTAssertFalse(recorder.hasDraft)
    }

    func testLockedReleaseKeepsRecordingUntilExplicitStop() async {
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { Recording(url: $0) }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap()
        recorder.lock(); recorder.endHold()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(recorder.isLocked)
        recorder.stop()
        XCTAssertNotNil(recorder.preview)
        XCTAssertFalse(recorder.isLocked)
        XCTAssertFalse(recorder.isTranscribing)
        recorder.cancel()
    }

    func testMicrophoneDenialDoesNotProduceDraftOrStartSession() async {
        var activated = false
        let recorder = CoveVoiceRecorder(requestPermission: { false }, makeRecorder: { Recording(url: $0) }, activateSession: { activated = true }, deactivateSession: {})
        await recorder.startFromExplicitTap()
        XCTAssertFalse(activated)
        XCTAssertFalse(recorder.hasDraft)
        XCTAssertNotNil(recorder.errorMessage)
    }

    func testMeterUsesMeasuredPowerAndMaximumDurationStopsToPreview() async {
        var recording: Recording!
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { url in recording = Recording(url: url); return recording }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap()
        recorder.updateRecording()
        XCTAssertEqual(Double(recorder.levels.last!), 0.1, accuracy: 0.001)
        recording.power = .nan
        recorder.updateRecording()
        XCTAssertEqual(recorder.levels.last, 0)
        recording.currentTime = 120
        recorder.updateRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNotNil(recorder.preview)
        XCTAssertFalse(recorder.isTranscribing)
        recorder.cancel()
    }

    func testTooShortRecordingIsDiscardedNotSent() async {
        var recording: Recording!
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { url in recording = Recording(url: url); recording.currentTime = 0.1; return recording }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap(); recorder.stop()
        XCTAssertNil(recorder.preview)
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path))
    }

    func testConsumeReturnsExactOriginalBytesAndDeletesTemporaryFile() async {
        var recording: Recording!
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { url in recording = Recording(url: url); return recording }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap(); recorder.stop()
        XCTAssertEqual(recorder.consumePreview(), recording.bytes)
        XCTAssertFalse(recorder.hasDraft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path))
    }

    func testHoldReleaseReturnsOriginalAudioExactlyOnceWithoutTranscript() async {
        var recording: Recording!
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { url in recording = Recording(url: url); return recording }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap()
        XCTAssertEqual(recorder.finishHoldForSending(), recording.bytes)
        XCTAssertNil(recorder.finishHoldForSending())
        XCTAssertFalse(recorder.isTranscribing)
        XCTAssertEqual(recorder.transcript, "")
        // Keep the source until the durable outbox accepts the file.
        XCTAssertNotNil(recorder.preview)
        recorder.cancel()
    }

    func testCancelledHoldCannotSendEvenWhenItHadRecordedBytes() async {
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { Recording(url: $0) }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap()
        recorder.cancel()
        XCTAssertNil(recorder.finishHoldForSending())
        XCTAssertNil(recorder.preview)
    }

    func testMaximumLengthIsSentOnlyAfterHoldRelease() async {
        var recording: Recording!
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { url in recording = Recording(url: url); return recording }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap()
        recording.currentTime = 120
        recorder.updateRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.isHolding)
        XCTAssertEqual(recorder.finishHoldForSending(), recording.bytes)
        XCTAssertNil(recorder.finishHoldForSending())
        recorder.cancel()
    }

    func testWholeInputHoldUsesUpwardCancelWithoutLockOrLeftCancel() {
        XCTAssertFalse(CoveVoiceHoldButton.Coordinator.shouldCancel(translationY: -59))
        XCTAssertTrue(CoveVoiceHoldButton.Coordinator.shouldCancel(translationY: -60))
        XCTAssertTrue(CoveVoiceHoldButton.Coordinator.shouldCancel(translationY: -120))
        XCTAssertFalse(CoveVoiceHoldButton.Coordinator.shouldCancel(translationY: 0))
    }

    func testLockedGestureCannotSendOnReleaseOrAfterExplicitStop() async {
        let recorder = CoveVoiceRecorder(requestPermission: { true }, makeRecorder: { Recording(url: $0) }, activateSession: {}, deactivateSession: {})
        await recorder.startFromExplicitTap()
        XCTAssertTrue(recorder.lock())
        XCTAssertNil(recorder.finishHoldForSending())
        XCTAssertTrue(recorder.isRecording)
        recorder.stop()
        XCTAssertNotNil(recorder.preview) // Explicit locked Send can enqueue these bytes.
        XCTAssertNil(recorder.finishHoldForSending())
        recorder.cancel()
    }

    func testPendingPermissionCannotBecomeLockedRecording() async {
        var permission: CheckedContinuation<Bool, Never>?
        let asked = expectation(description: "permission pending")
        var starts = 0
        let recorder = CoveVoiceRecorder(requestPermission: {
            await withCheckedContinuation { permission = $0; asked.fulfill() }
        }, makeRecorder: { url in starts += 1; return Recording(url: url) }, activateSession: {}, deactivateSession: {})
        let task = Task { await recorder.startFromExplicitTap() }
        await fulfillment(of: [asked], timeout: 1)
        XCTAssertFalse(recorder.lock())
        XCTAssertNil(recorder.finishHoldForSending())
        permission?.resume(returning: true)
        await task.value
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(recorder.hasDraft)
    }

    func testAccessibleHoldCannotReenterRecordingOrDisabledPreview() {
        var activations = 0
        func makeButton(disabled: Bool, canStart: Bool) -> CoveVoiceHoldButton {
            CoveVoiceHoldButton(title: "按住说话", recording: false, disabled: disabled,
                allowsNewRecording: canStart, begin: {}, cancel: {}, end: {},
                accessibleRecord: { activations += 1 })
        }
        let coordinator = makeButton(disabled: false, canStart: false).makeCoordinator()
        XCTAssertFalse(coordinator.accessibleTap())
        XCTAssertEqual(activations, 0)
        coordinator.parent = makeButton(disabled: true, canStart: true)
        XCTAssertFalse(coordinator.accessibleTap())
        XCTAssertEqual(activations, 0)
        coordinator.parent = makeButton(disabled: false, canStart: true)
        XCTAssertTrue(coordinator.accessibleTap())
        XCTAssertEqual(activations, 1)
        coordinator.active = true
        XCTAssertFalse(coordinator.accessibleTap())
        XCTAssertEqual(activations, 1)
    }

    func testVoiceDurationFormatting() {
        XCTAssertEqual(coveVoiceTime(0), "0:00")
        XCTAssertEqual(coveVoiceTime(61.9), "1:01")
        XCTAssertEqual(coveVoiceTime(.nan), "0:00")
        XCTAssertEqual(coveVoiceTime(-1), "0:00")
    }
}
