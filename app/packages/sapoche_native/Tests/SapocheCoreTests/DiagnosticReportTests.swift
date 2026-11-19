import XCTest
@testable import SapocheCore

final class DiagnosticReportTests: XCTestCase {
    func testACrashIsOneLineWithTheSignalTheReasonAndTheInnermostFramesOfTheBlamedThread() throws {
        let lines = DiagnosticReport.lines(try fixture("metrickit_diagnostics"))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(
            lines[0],
            "crash signal=11 exceptionType=1 exceptionCode=1 terminationReason=Namespace SIGNAL, Code 11 Segmentation fault "
                + "build=101 @ libsystem_kernel.dylib+400 | Runner+300 | UIKitCore+200")
    }

    func testAHangKeepsItsDurationAndNeedsNoMoreThanItHas() throws {
        let lines = DiagnosticReport.lines(try fixture("metrickit_diagnostics"))
        XCTAssertEqual(lines[1], "hang hangDuration=3.4 sec build=101 @ Runner+5")
    }

    func testWhatIsNotADiagnosticGivesNothingAndDoesNotThrow() {
        XCTAssertEqual(DiagnosticReport.lines(Data("not json".utf8)), [])
        XCTAssertEqual(DiagnosticReport.lines(Data("[1, 2]".utf8)), [])
        XCTAssertEqual(DiagnosticReport.lines(Data("{}".utf8)), [])
        XCTAssertEqual(DiagnosticReport.lines(Data(#"{"crashDiagnostics": [{}]}"#.utf8)), ["crash"])
    }
}
