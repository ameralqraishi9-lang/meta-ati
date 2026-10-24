import Foundation

public struct StudyQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let text: String
        public init(label: String, text: String) {
            self.label = label
            self.text = text
        }
    }

    public let stem: String
    public let options: [Option]
    public var permitsMultipleAnswers: Bool {
        let value = Self.normalize(stem)
        return value.contains("select all") || value.contains("choose all")
            || value.contains("select two") || value.contains("select three")
    }
    public var text: String {
        ([stem] + options.map { "\($0.label). \($0.text)" }).joined(separator: "\n")
    }
    /// Retains punctuation, units, decimal points, negatives, and choice order.
    /// Deliberately does not fuzzy-match clinically different questions.
    public var fingerprint: String { Self.normalize(text) }

    public static func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public enum QuestionParser {
    public enum Result: Equatable, Sendable {
        case question(StudyQuestion)
        case incomplete
        case restricted
    }

    /// A best-effort stop for explicit assessment banners; this is not a proctor detector.
    public static func isRestricted(_ text: String) -> Bool {
        let value = StudyQuestion.normalize(text)
        return ["proctored exam", "proctored assessment", "lockdown browser",
                "respondus monitor", "graded assessment", "graded exam", "timed exam"]
            .contains(where: value.contains)
    }

    public static func parse(_ text: String, confidence: Float = 1) -> Result {
        if isRestricted(text) { return .restricted }
        guard confidence >= 0.85, text.count >= 60, text.count <= 8000 else { return .incomplete }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pattern = #"^\(?([A-Fa-f])[\.)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .incomplete }
        var stem: [String] = []
        var labels: [String] = []
        var bodies: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let labelRange = Range(match.range(at: 1), in: line),
               let bodyRange = Range(match.range(at: 2), in: line) {
                labels.append(String(line[labelRange]).uppercased())
                bodies.append(String(line[bodyRange]))
            } else if bodies.isEmpty {
                stem.append(line)
            } else {
                bodies[bodies.count - 1] += " " + line
            }
        }
        let prompt = stem.joined(separator: " ")
        let lower = prompt.lowercased()
        let expected = Array(["A", "B", "C", "D", "E", "F"].prefix(labels.count))
        guard (4...6).contains(labels.count), labels == expected,
              bodies.allSatisfy({ $0.count >= 3 }), prompt.count >= 20,
              lower.contains("?") || ["which", "select", "identify", "what", "the nurse should"]
                .contains(where: lower.contains) else { return .incomplete }
        return .question(StudyQuestion(stem: prompt, options: zip(labels, bodies).map {
            StudyQuestion.Option(label: $0.0, text: $0.1)
        }))
    }
}
