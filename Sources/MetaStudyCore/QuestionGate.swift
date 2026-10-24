import Foundation

/// Pure state machine: two matching observations over 1.2 seconds, one request at
/// a time, eight seconds between attempts, and a bounded session-only answer cache.
public struct QuestionGate: Sendable {
    public private(set) var current: StudyQuestion?
    private var firstSeen: TimeInterval = 0
    private var lastSeen: TimeInterval = 0
    private var observations = 0
    private var lastRequest: TimeInterval = -.infinity
    private var inFlight: String?
    private var answered: [String] = []

    public init() {}

    @discardableResult
    public mutating func observe(_ question: StudyQuestion?, at time: TimeInterval) -> Bool {
        let changed = current?.fingerprint != question?.fingerprint
        if changed || time - lastSeen > 3 {
            firstSeen = time
            observations = 0
        }
        current = question
        lastSeen = time
        observations += question == nil ? 0 : 1
        return changed
    }

    public mutating func claim(at time: TimeInterval) -> StudyQuestion? {
        guard let question = current, isStable(at: time),
              time - lastRequest >= 8, inFlight == nil,
              !answered.contains(question.fingerprint) else { return nil }
        lastRequest = time
        inFlight = question.fingerprint
        return question
    }

    public func isStable(at time: TimeInterval) -> Bool {
        current != nil && observations >= 2 && time - firstSeen >= 1.2 && time - lastSeen <= 3
    }

    public mutating func finish(_ question: StudyQuestion, succeeded: Bool) {
        guard inFlight == question.fingerprint else { return }
        inFlight = nil
        if succeeded {
            answered.append(question.fingerprint)
            if answered.count > 64 { answered.removeFirst() }
        }
    }

    public mutating func cancelRequest() { inFlight = nil }
}
