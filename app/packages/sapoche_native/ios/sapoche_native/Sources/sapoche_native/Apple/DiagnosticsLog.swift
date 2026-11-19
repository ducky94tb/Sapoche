import MetricKit

/// Crashes, hangs and the like that the system reports on the next launch after they happened (MetricKit), written into
/// the log of the app, where "Copy log" finds them. iOS gives no word of a crash while it happens, so unlike on Android
/// the line comes a launch late, and the log itself is kept in memory only. Nothing leaves the phone.
final class DiagnosticsLog: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsLog()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for line in DiagnosticReport.lines(payload.jsonRepresentation()) {
                EventLog.d("diagnostic", line)
            }
        }
    }
}
