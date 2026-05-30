import XCTest
@testable import Steno

final class LogStoreTests: XCTestCase {
    var store: LogStore!

    override func setUp() {
        super.setUp()
        store = LogStore(capacity: 5)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func test_append_addsEventToSubsystemBuffer() {
        store.append(LogEvent(level: .info, subsystem: .audio, message: "hello"))
        XCTAssertEqual(store.count(for: .audio), 1)
        XCTAssertEqual(store.count(for: .transcription), 0)
    }

    func test_append_partitionsBySubsystem() {
        store.append(LogEvent(level: .info, subsystem: .audio, message: "a"))
        store.append(LogEvent(level: .info, subsystem: .transcription, message: "t"))
        store.append(LogEvent(level: .info, subsystem: .audio, message: "a2"))

        XCTAssertEqual(store.count(for: .audio), 2)
        XCTAssertEqual(store.count(for: .transcription), 1)
        XCTAssertEqual(store.count(for: .diarization), 0)
    }

    func test_append_evictsOldestWhenCapacityExceeded() {
        for i in 0..<10 {
            store.append(LogEvent(level: .info, subsystem: .audio, message: "msg\(i)"))
        }
        XCTAssertEqual(store.count(for: .audio), 5)
        let snapshot = store.snapshot(subsystems: [.audio], minLevel: .debug)
        XCTAssertEqual(snapshot.first?.message, "msg5")
        XCTAssertEqual(snapshot.last?.message, "msg9")
    }

    func test_snapshot_filtersBySubsystem() {
        store.append(LogEvent(level: .info, subsystem: .audio, message: "a"))
        store.append(LogEvent(level: .info, subsystem: .transcription, message: "t"))
        store.append(LogEvent(level: .info, subsystem: .storage, message: "s"))

        let audioOnly = store.snapshot(subsystems: [.audio], minLevel: .debug)
        XCTAssertEqual(audioOnly.count, 1)
        XCTAssertEqual(audioOnly.first?.message, "a")

        let multi = store.snapshot(subsystems: [.audio, .storage], minLevel: .debug)
        XCTAssertEqual(multi.count, 2)
    }

    func test_snapshot_filtersByMinLevel() {
        store.append(LogEvent(level: .debug, subsystem: .audio, message: "d"))
        store.append(LogEvent(level: .info, subsystem: .audio, message: "i"))
        store.append(LogEvent(level: .warning, subsystem: .audio, message: "w"))
        store.append(LogEvent(level: .error, subsystem: .audio, message: "e"))

        let warningAndAbove = store.snapshot(subsystems: [.audio], minLevel: .warning)
        XCTAssertEqual(warningAndAbove.count, 2)
        XCTAssertEqual(warningAndAbove.map(\.message), ["w", "e"])
    }

    func test_snapshot_sortsByTimestamp() {
        let now = Date()
        store.append(LogEvent(level: .info, subsystem: .audio, message: "second", timestamp: now.addingTimeInterval(1)))
        store.append(LogEvent(level: .info, subsystem: .transcription, message: "first", timestamp: now))
        store.append(LogEvent(level: .info, subsystem: .audio, message: "third", timestamp: now.addingTimeInterval(2)))

        let all = store.snapshot()
        XCTAssertEqual(all.map(\.message), ["first", "second", "third"])
    }

    func test_clear_emptiesAllSubsystems() {
        store.append(LogEvent(level: .info, subsystem: .audio, message: "a"))
        store.append(LogEvent(level: .info, subsystem: .transcription, message: "t"))
        store.clear()

        XCTAssertEqual(store.count(for: .audio), 0)
        XCTAssertEqual(store.count(for: .transcription), 0)
    }

    func test_lastEventTime_returnsNilWhenEmpty() {
        XCTAssertNil(store.lastEventTime(for: .audio))
    }

    func test_lastEventTime_returnsMostRecent() throws {
        let now = Date()
        store.append(LogEvent(level: .info, subsystem: .audio, message: "1", timestamp: now))
        store.append(LogEvent(level: .info, subsystem: .audio, message: "2", timestamp: now.addingTimeInterval(1)))

        let actual = try XCTUnwrap(store.lastEventTime(for: .audio))
        XCTAssertEqual(actual.timeIntervalSince1970,
                       now.addingTimeInterval(1).timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func test_exportText_formatsEventsAsLines() {
        let now = Date()
        store.append(LogEvent(level: .error, subsystem: .audio, message: "boom", timestamp: now))

        let text = store.exportText(subsystems: [.audio], minLevel: .debug)
        XCTAssertTrue(text.contains("[ERROR]"))
        XCTAssertTrue(text.contains("audio"))
        XCTAssertTrue(text.contains("boom"))
    }

    func test_concurrentAppend_isThreadSafe() {
        let largeStore = LogStore(capacity: 10_000)
        let expectation = self.expectation(description: "concurrent appends complete")
        expectation.expectedFulfillmentCount = 10

        for threadIndex in 0..<10 {
            DispatchQueue.global().async {
                for i in 0..<100 {
                    largeStore.append(LogEvent(level: .info, subsystem: .audio, message: "t\(threadIndex)-\(i)"))
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(largeStore.count(for: .audio), 1000)
    }
}
