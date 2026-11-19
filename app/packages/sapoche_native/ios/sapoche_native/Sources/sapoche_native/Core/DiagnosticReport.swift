import Foundation

/// What the system says of a run that went wrong (MetricKit's `MXDiagnosticPayload`, as the JSON it gives), turned into the
/// few lines the app keeps in its own log. Nothing leaves the phone. Kept here, apart from MetricKit, so that it is
/// tested on Linux: the shape of the JSON is Apple's, and every key is optional.
enum DiagnosticReport {
    /// The innermost frames shown for a crash or a hang.
    private static let frames = 3

    /// One line for each crash, hang, CPU or disk-write diagnostic in [payload]; empty when it is not that JSON.
    static func lines(_ payload: Data) -> [String] {
        guard let root = JSON.parse(data: payload), root.object != nil else { return [] }
        var lines: [String] = []
        for (key, kind) in [("crashDiagnostics", "crash"), ("hangDiagnostics", "hang"),
                            ("cpuExceptionDiagnostics", "cpu"), ("diskWriteExceptionDiagnostics", "disk-write")] {
            for entry in root[key].array { lines.append(line(kind, entry)) }
        }
        return lines
    }

    private static func line(_ kind: String, _ entry: JSON) -> String {
        let meta = entry["diagnosticMetaData"]
        var parts: [String] = []
        for key in ["signal", "exceptionType", "exceptionCode", "hangDuration", "totalCPUTime", "totalWritesCaused"] {
            if let text = meta[key].string { parts.append("\(key)=\(text)") }
        }
        if let reason = meta["terminationReason"].string, !reason.isEmpty {
            parts.append("terminationReason=\(reason.split(whereSeparator: \.isNewline).joined(separator: " "))")
        }
        if let version = meta["appBuildVersion"].string { parts.append("build=\(version)") }
        let top = innermost(entry["callStackTree"])
        if !top.isEmpty { parts.append("@ " + top.joined(separator: " | ")) }
        return ([kind] + parts).joined(separator: " ")
    }

    /// The innermost [frames] of the thread the system blames (the first when none is marked): the tree begins at the
    /// outermost frame, so the way down the first branch is followed to its end.
    private static func innermost(_ tree: JSON) -> [String] {
        let stacks = tree["callStacks"].array
        guard let stack = stacks.first(where: { $0["threadAttributed"].bool == true }) ?? stacks.first else { return [] }
        var chain: [String] = []
        var frame = stack["callStackRootFrames"].array.first
        while let current = frame {
            let name = current["binaryName"].string ?? "?"
            let offset = current["offsetIntoBinaryTextSegment"].string.map { "+\($0)" } ?? ""
            chain.append(name + offset)
            frame = current["subFrames"].array.first
        }
        return Array(chain.suffix(frames).reversed())
    }
}
