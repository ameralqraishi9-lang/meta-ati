import XCTest
@testable import MetaStudyCore

final class StudyCoreTests: XCTestCase {
    private let text = """
    Which action should the nurse take first for this practice scenario?
    A. Assess the client
    B. Document the event
    C. Review the chart
    D. Arrange teaching
    """

    private func question(_ value: String? = nil) throws -> StudyQuestion {
        guard case .question(let result) = QuestionParser.parse(value ?? text) else {
            throw AnswerError.invalidResponse
        }
        return result
    }

    func testParsesCompleteQuestionAndWrappedChoices() throws {
        let q = try question(text.replacingOccurrences(of: "Assess the client", with: "Assess the\nclient"))
        XCTAssertEqual(q.options.count, 4)
        XCTAssertEqual(q.options[0].text, "Assess the client")
    }

    func testRejectsCroppedQuestionWithOnlyThreeChoices() {
        XCTAssertEqual(QuestionParser.parse(text.components(separatedBy: "\nD.").first!), .incomplete)
    }

    func testRejectsMissingAndRepeatedLabels() {
        XCTAssertEqual(QuestionParser.parse(text.replacingOccurrences(of: "B.", with: "C.")), .incomplete)
        XCTAssertEqual(QuestionParser.parse(text.replacingOccurrences(of: "B.", with: "E.")), .incomplete)
    }

    func testLowConfidenceNeverTriggersAI() {
        XCTAssertEqual(QuestionParser.parse(text, confidence: 0.84), .incomplete)
    }

    func testRestrictionCheckedEvenWithLowConfidence() {
        XCTAssertEqual(QuestionParser.parse("ATI proctored assessment\n" + text, confidence: 0.1), .restricted)
        XCTAssertEqual(QuestionParser.parse("Respondus Monitor\n" + text), .restricted)
    }

    func testPracticeNCLEXLabelIsAllowed() throws {
        XCTAssertEqual(try question("NCLEX practice\n" + text).options.count, 4)
    }

    func testSixChoiceSATAAndParenthesizedLabels() throws {
        let value = text.replacingOccurrences(of: "Which action", with: "Select all that apply. Which actions")
            .replacingOccurrences(of: "A.", with: "(a)") + "\nE. Check the history\nF. Evaluate the response"
        let q = try question(value)
        XCTAssertEqual(q.options.count, 6)
        XCTAssertTrue(q.permitsMultipleAnswers)
    }

    func testFingerprintRetainsNegationsDecimalsAndChoiceOrder() throws {
        let q = try question()
        XCTAssertNotEqual(q.fingerprint, try question(text.replacingOccurrences(of: "should", with: "should NOT")).fingerprint)
        XCTAssertNotEqual(try question(text + " 0.5 mg").fingerprint, try question(text + " 5 mg").fingerprint)
        let swapped = text.replacingOccurrences(of: "Assess the client", with: "TEMP")
            .replacingOccurrences(of: "Document the event", with: "Assess the client")
            .replacingOccurrences(of: "TEMP", with: "Document the event")
        XCTAssertNotEqual(q.fingerprint, try question(swapped).fingerprint)
    }

    func testWhitespaceDoesNotCauseDuplicateRequest() throws {
        XCTAssertEqual(try question().fingerprint, try question(text.replacingOccurrences(of: "the", with: "  the ")).fingerprint)
    }

    func testOneObservationIsNeverEnough() throws {
        var gate = QuestionGate()
        gate.observe(try question(), at: 0)
        XCTAssertNil(gate.claim(at: 2))
    }

    func testWaitsForSteadinessAndSerializesRequests() throws {
        var gate = QuestionGate()
        let q = try question()
        gate.observe(q, at: 0)
        gate.observe(q, at: 0.5)
        XCTAssertNil(gate.claim(at: 0.5))
        gate.observe(q, at: 1.4)
        XCTAssertEqual(gate.claim(at: 1.4), q)
        gate.observe(q, at: 10)
        XCTAssertNil(gate.claim(at: 10))
    }

    func testCompletedQuestionIsNotSentAgain() throws {
        var gate = QuestionGate()
        let q = try question()
        gate.observe(q, at: 0); gate.observe(q, at: 2)
        XCTAssertNotNil(gate.claim(at: 2))
        gate.finish(q, succeeded: true)
        gate.observe(nil, at: 10)
        gate.observe(q, at: 11); gate.observe(q, at: 13)
        XCTAssertNil(gate.claim(at: 13))
    }

    func testNewQuestionCancelsOldClaimWithoutCachingIt() throws {
        var gate = QuestionGate()
        let a = try question()
        let b = try question(text.replacingOccurrences(of: "first", with: "last"))
        gate.observe(a, at: 0); gate.observe(a, at: 2)
        XCTAssertNotNil(gate.claim(at: 2))
        XCTAssertTrue(gate.observe(b, at: 3))
        gate.cancelRequest()
        gate.finish(a, succeeded: true) // A late callback must not settle a new request.
        gate.observe(b, at: 9); gate.observe(b, at: 11)
        XCTAssertEqual(gate.claim(at: 11), b)
        gate.finish(a, succeeded: true)
        gate.observe(b, at: 12)
        XCTAssertNil(gate.claim(at: 12))
    }

    func testCooldownAndFailedAttemptCanBeRetried() throws {
        var gate = QuestionGate()
        let q = try question()
        gate.observe(q, at: 0); gate.observe(q, at: 2)
        XCTAssertNotNil(gate.claim(at: 2))
        gate.finish(q, succeeded: false)
        gate.observe(q, at: 3)
        XCTAssertNil(gate.claim(at: 3))
        gate.observe(q, at: 9); gate.observe(q, at: 11)
        XCTAssertNotNil(gate.claim(at: 11))
    }

    func testLongFrameGapResetsSteadiness() throws {
        var gate = QuestionGate()
        gate.observe(try question(), at: 0)
        gate.observe(try question(), at: 8)
        XCTAssertNil(gate.claim(at: 8))
    }

    func testBlankFrameInvalidatesCurrentQuestion() throws {
        var gate = QuestionGate()
        gate.observe(try question(), at: 0); gate.observe(try question(), at: 2)
        gate.observe(nil, at: 2.1)
        XCTAssertNil(gate.claim(at: 3))
    }

    func testAPIKeyIsHeaderOnlyAndOnlyTextIsUploaded() throws {
        let request = try GeminiStudyClient(apiKey: "TEST-NOT-A-REAL-KEY").request(for: question())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertFalse(request.url!.absoluteString.contains("TEST-NOT-A-REAL-KEY"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "TEST-NOT-A-REAL-KEY")
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(body["systemInstruction"])
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(raw.contains("inlineData"))
        XCTAssertFalse(raw.contains("TEST-NOT-A-REAL-KEY"))
    }

    func testMissingKeyAndInvalidModelRejectedBeforeNetwork() throws {
        let q = try question()
        XCTAssertThrowsError(try GeminiStudyClient(apiKey: "").request(for: q))
        XCTAssertThrowsError(try GeminiStudyClient(apiKey: "test", model: "../../elsewhere").request(for: q))
    }

    private func response(_ answer: StudyAnswer, finish: String = "STOP") throws -> Data {
        let text = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["candidates": [[
            "finishReason": finish, "content": ["parts": [["text": text]]]
        ]]])
    }

    private func answer(labels: [String] = ["A"], status: StudyAnswer.Status = .answered) -> StudyAnswer {
        StudyAnswer(status: status, selectedOptions: labels, conciseAnswer: "Review the assessment first.",
                    rationale: "This is an example explanation for response-validation testing.", mnemonic: "Assess before acting.")
    }

    func testValidStructuredAnswer() throws {
        XCTAssertEqual(try GeminiStudyClient.decode(response(answer()), for: question()), answer())
    }

    func testUnknownLabelsAndDuplicatesRejected() throws {
        let q = try question()
        XCTAssertThrowsError(try GeminiStudyClient.decode(response(answer(labels: ["F"])), for: q))
        XCTAssertThrowsError(try GeminiStudyClient.decode(response(answer(labels: ["A", "A"])), for: q))
    }

    func testSingleAnswerAndSATAAreValidatedDifferently() throws {
        XCTAssertThrowsError(try GeminiStudyClient.decode(response(answer(labels: ["A", "B"])), for: question()))
        let sata = try question("Select all that apply. " + text)
        XCTAssertNoThrow(try GeminiStudyClient.decode(response(answer(labels: ["A", "B"])), for: sata))
    }

    func testRefusalMustNotIncludeAnswerLabels() throws {
        XCTAssertThrowsError(try answer(status: .outOfScope).validated(for: question()))
        XCTAssertNoThrow(try answer(labels: [], status: .needsClearerImage).validated(for: question()))
    }

    func testTruncatedAndBlockedResponsesAreNotDisplayed() throws {
        let q = try question()
        XCTAssertThrowsError(try GeminiStudyClient.decode(response(answer(), finish: "MAX_TOKENS"), for: q))
        XCTAssertThrowsError(try GeminiStudyClient.decode(Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8), for: q))
    }
}
