import Foundation

public struct StudyAnswer: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case answered, needsClearerImage, outOfScope
    }
    public let status: Status
    public let selectedOptions: [String]
    public let conciseAnswer: String
    public let rationale: String
    public let mnemonic: String

    public init(status: Status, selectedOptions: [String], conciseAnswer: String,
                rationale: String, mnemonic: String) {
        self.status = status
        self.selectedOptions = selectedOptions
        self.conciseAnswer = conciseAnswer
        self.rationale = rationale
        self.mnemonic = mnemonic
    }

    public func validated(for question: StudyQuestion) throws -> StudyAnswer {
        let allowed = Set(question.options.map(\.label))
        guard conciseAnswer.count <= 240, rationale.count <= 2500, mnemonic.count <= 300,
              !conciseAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(selectedOptions).count == selectedOptions.count,
              selectedOptions.allSatisfy(allowed.contains),
              selectedOptions.count <= 1 || question.permitsMultipleAnswers,
              status == .answered ? !selectedOptions.isEmpty : selectedOptions.isEmpty
        else { throw AnswerError.invalidResponse }
        return self
    }

    public var heading: String {
        status == .answered ? "Answer: " + selectedOptions.joined(separator: ", ") : "Check the question"
    }
}

public enum AnswerError: Error, LocalizedError {
    case invalidResponse, missingKey, invalidModel, rejected(Int), noAnswer
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The AI response was incomplete. Keep the full question in view and try again."
        case .missingKey: return "Add your Gemini API key in Settings before starting."
        case .invalidModel: return "Use a valid Gemini model ID in Settings."
        case .rejected(let code):
            if code == 429 { return "The AI request limit was reached. Wait before starting again." }
            if code == 400 || code == 401 || code == 403 { return "Check your Gemini API key, model access, and API settings." }
            if code == 404 { return "This Gemini model is unavailable. Update the model ID in Settings." }
            return "The AI service returned HTTP \(code). Try again later."
        case .noAnswer: return "The AI did not return an answer. Try a clearer, complete practice question."
        }
    }
}
