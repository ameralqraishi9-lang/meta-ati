import SwiftUI
import AVFoundation
import MetaStudyCore

@MainActor
final class StudyController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Ready for a practice session"
    @Published private(set) var recognizedText = ""
    @Published private(set) var answer: StudyAnswer?
    @Published private(set) var isThinking = false
    @Published var speakAnswers = false

    var onCard: ((String, String) -> Void)?
    var onAnswer: ((StudyAnswer) -> Void)?
    var onNewQuestion: (() -> Void)?
    private let reader = OCRReader()
    private let speaker = AVSpeechSynthesizer()
    private var gate = QuestionGate()
    private var client: GeminiStudyClient?
    private var sessionID = UUID()
    private var requestID = UUID()
    private var lastFrameTime: TimeInterval = -.infinity
    private var ocrTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var savedAnswers: [String: StudyAnswer] = [:]
    private var savedOrder: [String] = []

    func start(apiKey: String, model: String) {
        stop()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = AnswerError.missingKey.localizedDescription
            return
        }
        client = GeminiStudyClient(apiKey: apiKey, model: model)
        gate = QuestionGate()
        savedAnswers = [:]
        savedOrder = []
        running = true
        status = "Hold the whole question and A–D (or A–F) in view"
        onCard?("Study session", "Hold a complete practice question steady.")
    }

    func stop(message: String = "Study session stopped") {
        sessionID = UUID()
        running = false
        ocrTask?.cancel()
        ocrTask = nil
        cancelAnswer()
        client = nil
        gate = QuestionGate()
        answer = nil
        recognizedText = ""
        savedAnswers = [:]
        savedOrder = []
        lastFrameTime = -.infinity
        status = message
        onCard?("Study paused", message)
    }

    /// Invalidates pending AI output immediately on camera loss, pauses or a new question.
    func sourceUnavailable() {
        guard running else { return }
        sessionID = UUID()
        ocrTask?.cancel()
        ocrTask = nil
        cancelAnswer()
        gate.observe(nil, at: ProcessInfo.processInfo.systemUptime)
        answer = nil
        recognizedText = ""
        status = "Waiting for a clear camera view"
        onCard?("Study paused", "Waiting for the camera. No answer is current.")
    }

    /// Feed this from Meta DAT or VisionClaw's decoded UIImage frame callback.
    func receive(_ image: UIImage, isStill: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard running, ocrTask == nil, isStill || now - lastFrameTime >= 0.8 else { return }
        lastFrameTime = now
        let session = sessionID
        ocrTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reading = try await reader.read(image)
                guard !Task.isCancelled, session == sessionID, running else { return }
                ocrTask = nil
                consume(reading)
            } catch {
                guard session == sessionID, !Task.isCancelled else { return }
                ocrTask = nil
                sourceUnavailable()
                status = "Text recognition failed. Improve the light and keep the question in view."
            }
        }
    }

    private func consume(_ reading: OCRReader.Reading) {
        let now = ProcessInfo.processInfo.systemUptime
        recognizedText = reading.text
        switch QuestionParser.parse(reading.text, confidence: reading.confidence) {
        case .restricted:
            stop(message: "Practice materials only. This view contains an assessment restriction.")
        case .incomplete:
            let changed = gate.observe(nil, at: now)
            if changed {
                cancelAnswer()
                answer = nil
                onCard?("Hold steady", "Keep the full question and every choice visible.")
            }
            status = "Waiting for clear text and all choices A–D (or A–F)"
        case .question(let question):
            if gate.observe(question, at: now) {
                cancelAnswer()
                answer = nil
                onCard?("Reading question", "Keep the full question steady.")
                onNewQuestion?()
            }
            if let saved = savedAnswers[question.fingerprint], gate.isStable(at: now) {
                if answer != saved {
                    answer = saved
                    onAnswer?(saved)
                }
                status = "Previously explained in this session"
                return
            }
            guard let ready = gate.claim(at: now), let client else {
                if answer == nil && !isThinking { status = "Checking that the question is steady…" }
                return
            }
            isThinking = true
            status = "Preparing an explanation…"
            let session = sessionID
            let request = UUID()
            requestID = request
            requestTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await client.answer(ready)
                    guard !Task.isCancelled, running, session == sessionID,
                          request == requestID, gate.current?.fingerprint == ready.fingerprint else { return }
                    // Cache all valid outcomes, including requests for a clearer image, to avoid loops.
                    gate.finish(ready, succeeded: true)
                    isThinking = false
                    requestTask = nil
                    answer = result
                    savedAnswers[ready.fingerprint] = result
                    savedOrder.append(ready.fingerprint)
                    if savedOrder.count > 64 { savedAnswers.removeValue(forKey: savedOrder.removeFirst()) }
                    status = result.status == .answered ? "Explanation ready · verify with your course material" : "Review the question"
                    onAnswer?(result)
                    if speakAnswers { speak(result) }
                } catch {
                    guard !Task.isCancelled, running, session == sessionID, request == requestID else { return }
                    // Stop instead of retrying paid requests indefinitely on a network or key failure.
                    stop(message: (error as? AnswerError)?.localizedDescription ?? "The AI request failed. Check your connection, then start again.")
                }
            }
        }
    }

    private func cancelAnswer() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        gate.cancelRequest()
        isThinking = false
        speaker.stopSpeaking(at: .immediate)
    }

    private func speak(_ answer: StudyAnswer) {
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: answer.heading + ". " + answer.conciseAnswer + ". " + answer.rationale)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaker.speak(utterance)
    }
}
