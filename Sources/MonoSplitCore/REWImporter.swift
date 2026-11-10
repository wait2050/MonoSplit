import Foundation

public struct ImportIssue: Identifiable, Sendable {
    public var line: Int
    public var message: String
    public var id: String { "\(line)-\(message)" }
    public var description: String { "第 \(line) 行 · \(message)" }
}

public struct EQImportResult: Sendable {
    public var bands: [EQBand] = []
    public var preampDB: Double = 0
    public var issues: [ImportIssue] = []
    public var canApply: Bool { issues.isEmpty && !bands.isEmpty }
}

public enum REWImporter {
    private static func matches(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
    private static func parameter(_ key: String, in text: String) -> Double? {
        guard let match = matches("\\b" + key + "\\s+([^\\s]+)", in: text) else { return nil }
        let token = match[1].replacingOccurrences(of: "(?i)(Hz|dB)$", with: "", options: .regularExpression)
        return Double(token)
    }

    public static func parseEQ(_ text: String) -> EQImportResult {
        var result = EQImportResult()
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "")
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("*") { continue }
            if line.lowercased().hasPrefix("preamp") {
                if let match = matches("^Preamp\\s*:\\s*([^\\s]+)\\s*(?:dB)?\\s*$", in: line), let value = Double(match[1].replacingOccurrences(of: "(?i)dB$", with: "", options: .regularExpression)), value.isFinite, (-60...12).contains(result.preampDB + value) {
                    result.preampDB += value
                } else { result.issues.append(ImportIssue(line: lineNumber, message: "前级增益无效，应在 −60 至 +12 dB")) }
                continue
            }
            if line.lowercased().hasPrefix("channel:") {
                let selection = line.dropFirst(8).trimmingCharacters(in: .whitespaces).lowercased()
                if selection != "all" { result.issues.append(ImportIssue(line: lineNumber, message: "文件包含通道选择，请分别导出单支路滤波器")) }
                continue
            }
            // APO routing, includes and convolution cannot be represented as a PEQ chain.
            if ["include:", "copy:", "convolution:", "graphicEQ:", "delay:", "device:", "stage:", "if:", "elseif:", "else:", "endif:", "eval:"].contains(where: { line.lowercased().hasPrefix($0.lowercased()) }) {
                result.issues.append(ImportIssue(line: lineNumber, message: "该 APO 指令不受支持"))
                continue
            }
            guard line.lowercased().hasPrefix("filter") else { continue }
            if line.lowercased().hasPrefix("filter settings") { continue }
            guard let match = matches("^Filter(?:\\s+(\\d+))?\\s*:\\s*(ON|OFF)\\s+(\\S+)(.*)$", in: line) else {
                result.issues.append(ImportIssue(line: lineNumber, message: "滤波器格式无效"))
                continue
            }
            let enabled = match[2].uppercased() == "ON", type = match[3].uppercased(), parameters = match[4]
            if type == "NONE" { continue }
            let kind: FilterKind
            switch type {
            case "PK", "PEQ": kind = .peak
            case "LSC", "LSQ": kind = .lowShelf
            case "HSC", "HSQ": kind = .highShelf
            case "LS": kind = .lowShelf
            case "HS": kind = .highShelf
            case "HP", "HPQ": kind = .highPass
            case "LP", "LPQ": kind = .lowPass
            default:
                result.issues.append(ImportIssue(line: lineNumber, message: "滤波器 \(type) 不受支持，请使用 Generic / Equalizer APO 的 PK、LSC、HSC、HPQ 或 LPQ"))
                continue
            }
            guard let frequency = parameter("Fc", in: parameters), frequency.isFinite, (1...96000).contains(frequency) else {
                result.issues.append(ImportIssue(line: lineNumber, message: "Fc 频率缺失或无效"))
                continue
            }
            if matches("\\bBW\\b", in: parameters) != nil {
                result.issues.append(ImportIssue(line: lineNumber, message: "带宽格式需先转为 Q"))
                continue
            }
            let q = parameter("Q", in: parameters) ?? (["HP", "LP", "LS", "HS", "LSC", "HSC"].contains(type) ? 1 / sqrt(2) : .nan)
            if matches("\\bQ\\b", in: parameters) != nil && parameter("Q", in: parameters) == nil {
                result.issues.append(ImportIssue(line: lineNumber, message: "Q 数值无效"))
                continue
            }
            let gain = kind.hasGain ? parameter("Gain", in: parameters) ?? .nan : 0
            guard q.isFinite, (0.05...100).contains(q), gain.isFinite, (-30...30).contains(gain) else {
                result.issues.append(ImportIssue(line: lineNumber, message: "Gain 或 Q 缺失或无效，带宽及斜率格式需先转为 Q"))
                continue
            }
            // A shelf with a slope parameter has different semantics from a Q shelf.
            if matches("(?:LS|HS|LSC|HSC)\\s+[-+0-9.]+\\s*dB", in: type + parameters) != nil {
                result.issues.append(ImportIssue(line: lineNumber, message: "架式滤波器的斜率格式不受支持"))
                continue
            }
            result.bands.append(EQBand(kind: kind, frequency: frequency, gainDB: gain, q: q, enabled: enabled))
            if result.bands.count > 20 { result.issues.append(ImportIssue(line: lineNumber, message: "超过每路最多 20 段滤波器")) }
        }
        if result.bands.isEmpty && result.issues.isEmpty { result.issues.append(ImportIssue(line: 1, message: "未找到滤波器，请从 REW 导出 Generic / Equalizer APO 参数文本")) }
        return result
    }

    public static func parseMeasurement(_ text: String, name: String, source: String) throws -> MeasurementReference {
        var points: [MeasurementPoint] = []
        var failures: [String] = []
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "")
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            let tokens = line.split { $0.isWhitespace || $0 == "," }
            guard let first = tokens.first else { continue }
            if first.lowercased().hasPrefix("freq") { continue }
            guard tokens.count == 2 || tokens.count == 3,
                  let frequency = Double(tokens[0]), let spl = Double(tokens[1]),
                  frequency.isFinite, frequency > 0, spl.isFinite else {
                failures.append("第 \(offset + 1) 行 · 应为频率、SPL 和可选相位")
                continue
            }
            var phase: Double?
            if tokens.count == 3 {
                guard let parsed = Double(tokens[2]), parsed.isFinite else {
                    failures.append("第 \(offset + 1) 行 · 相位无效")
                    continue
                }
                phase = parsed
            }
            points.append(MeasurementPoint(frequency: frequency, spl: spl, phase: phase))
            if points.count > 500_000 { throw MonoSplitError("测量文件超过 500,000 个数据点") }
        }
        if !failures.isEmpty { throw MonoSplitError(failures.prefix(12).joined(separator: "\n")) }
        guard points.count >= 2 else { throw MonoSplitError("测量文件至少需要两个有效频率点") }
        points.sort { $0.frequency < $1.frequency }
        guard zip(points, points.dropFirst()).allSatisfy({ $0.frequency < $1.frequency }) else { throw MonoSplitError("测量文件包含重复频率") }
        return MeasurementReference(name: name, source: source, points: points)
    }
}
