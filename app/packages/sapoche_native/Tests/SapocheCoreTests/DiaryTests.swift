import XCTest
@testable import SapocheCore

/// The same cases as `DiaryTest.kt`; both read `diary_levels.json`.
final class DiaryTests: XCTestCase {
    private func rows(_ name: String) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: fixture("diary_levels")) as! [String: Any]
        return json[name] as! [[String: Any]]
    }

    private func tmp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diary-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func line(_ i: Int, _ level: LogLevel) -> String {
        Diary.line(stamp: String(format: "11-23 14:02:%02d.000", i % 60), level: level, tag: "t", message: "n\(i) " + String(repeating: "x", count: 40))
    }

    func testLevelsAreInferredAsTheSharedFixtureSays() throws {
        for row in try rows("levels") {
            let tag = row["tag"] as! String, message = row["message"] as! String
            XCTAssertEqual(Diary.infer(tag: tag, message: message).rawValue, Character(row["level"] as! String), "[\(tag)] \(message)")
        }
    }

    func testTheLevelIsReadBackFromALine() throws {
        for row in try rows("lines") {
            let text = row["line"] as! String
            let letter = (row["level"] as? String).map { Character($0) }
            XCTAssertEqual(Diary.levelOf(text)?.rawValue, letter, text)
        }
    }

    func testALineIsBuiltInTheSharedShape() {
        XCTAssertEqual(Diary.line(stamp: "11-23 14:02:11.123", level: .warn, tag: "room", message: "closed: 1006"),
                       "11-23 14:02:11.123 W [room] closed: 1006")
    }

    func testNoiseNeverPushesKeyLinesOutOfReach() {
        let files = DiaryFiles(dir: tmp(), maxBytes: 2_000, maxKeyBytes: 10_000)
        files.append([line(1, .error), line(2, .main)])
        for i in 10..<400 { files.append([line(i, .detail)]) }
        let all = files.readAll()
        XCTAssertTrue(all.contains { $0.contains("n1 ") })
        XCTAssertTrue(all.contains { $0.contains("n2 ") })
        XCTAssertLessThan(all.count, 120)
        XCTAssertTrue(all.last!.contains("n399 "))
        XCTAssertEqual(all.count, Set(all).count)
    }

    func testTheFullFilesTurnOverWhenFull() {
        let dir = tmp()
        let files = DiaryFiles(dir: dir, maxBytes: 1_000, maxKeyBytes: 10_000)
        for i in 1...100 { files.append([line(i, .info)]) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("sapoche.log").path))?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sapoche.1.log").path))
        let all = files.readAll()
        XCTAssertTrue(all.last!.contains("n100 "))
        XCTAssertTrue((15...40).contains(all.count), "\(all.count)")
    }

    func testTheKeyFileKeepsTheNewerHalfWhenFull() {
        let dir = tmp()
        let files = DiaryFiles(dir: dir, maxBytes: 1_000_000, maxKeyBytes: 1_000)
        for i in 1...60 { files.append([line(i, .warn)]) }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("sapoche.log"))
        let keys = files.readAll()
        XCTAssertTrue(keys.last!.contains("n60 "))
        XCTAssertTrue((5...30).contains(keys.count), "\(keys.count)")
    }

    func testClearingRemovesEverything() {
        let files = DiaryFiles(dir: tmp())
        files.append([line(1, .error)])
        files.clear()
        XCTAssertEqual(files.readAll(), [])
    }

    func testAFileOfTheOldShapeIsDropped() throws {
        let dir = tmp()
        try "01:00:00.000 [log] old\n".write(to: dir.appendingPathComponent("sapoche.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DiaryFiles(dir: dir).readAll(), [])
    }

    func testTheLogOfALaterStartKnowsTheRunBeforeEndedBadly() {
        let dir = tmp()
        let files = DiaryFiles(dir: dir)
        files.append([Diary.line(stamp: "11-23 14:00:00.000", level: .main, tag: "log", message: EventLog.started),
                      Diary.line(stamp: "11-23 14:01:00.000", level: .error, tag: "crash", message: "boom")])
        let log = EventLog()
        log.start(dir: dir)
        XCTAssertTrue(log.previousRunFailed)
        XCTAssertTrue(log.lines().contains { $0.contains("[crash] boom") })
        log.clear()
        XCTAssertEqual(log.lines().count, 1)
    }
}
