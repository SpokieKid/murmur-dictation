import XCTest
@testable import Murmur

final class LiveAudioMixerTests: XCTestCase {
    func testMixesMicrophoneAndSystemFrames() {
        let emitted = expectation(description: "mixed frame emitted")
        let lock = NSLock()
        var firstFrame: [Float]?
        let mixer = LiveAudioMixer { frame in
            lock.lock()
            if firstFrame == nil {
                firstFrame = frame
                emitted.fulfill()
            }
            lock.unlock()
        }

        mixer.start()
        mixer.append(Array(repeating: 0.5, count: 320), from: .microphone)
        mixer.append(Array(repeating: 0.25, count: 320), from: .system)
        wait(for: [emitted], timeout: 1)
        mixer.stop()

        lock.lock()
        let frame = firstFrame
        lock.unlock()
        XCTAssertEqual(frame?.count, 320)
        XCTAssertEqual(frame?.first ?? 0, 0.54, accuracy: 0.0001)
        XCTAssertTrue(frame?.allSatisfy { abs($0 - 0.54) < 0.0001 } == true)
    }

    func testSingleAvailableSourceKeepsFullGain() {
        let emitted = expectation(description: "microphone frame emitted")
        let lock = NSLock()
        var firstFrame: [Float]?
        let mixer = LiveAudioMixer { frame in
            lock.lock()
            if firstFrame == nil {
                firstFrame = frame
                emitted.fulfill()
            }
            lock.unlock()
        }

        mixer.start()
        mixer.append(Array(repeating: 0.4, count: 320), from: .microphone)
        wait(for: [emitted], timeout: 1)
        mixer.stop()

        lock.lock()
        let first = firstFrame?.first
        lock.unlock()
        XCTAssertEqual(first ?? 0, 0.4, accuracy: 0.0001)
    }

    func testStopDrainsPrebufferedSamples() {
        let lock = NSLock()
        var frames: [[Float]] = []
        let mixer = LiveAudioMixer { frame in
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        mixer.start()
        mixer.append(Array(repeating: 0.3, count: 500), from: .system)
        mixer.stop()

        lock.lock()
        let captured = frames
        lock.unlock()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].first ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(captured[1][179], 0.3, accuracy: 0.0001)
        XCTAssertEqual(captured[1][180], 0, accuracy: 0.0001)
    }
}
