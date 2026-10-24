import UIKit
import Vision

actor OCRReader {
    struct Reading: Sendable { let text: String; let confidence: Float }

    func read(_ image: UIImage) throws -> Reading {
        guard let cgImage = image.cgImage else { return Reading(text: "", confidence: 0) }
        let orientation: CGImagePropertyOrientation
        switch image.imageOrientation {
        case .up: orientation = .up
        case .down: orientation = .down
        case .left: orientation = .left
        case .right: orientation = .right
        case .upMirrored: orientation = .upMirrored
        case .downMirrored: orientation = .downMirrored
        case .leftMirrored: orientation = .leftMirrored
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: orientation = .up
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false // Do not silently rewrite medication names or units.
        try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])
        let items = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        // Minimum confidence prevents one poorly read critical line from being averaged away.
        return Reading(text: items.map(\.string).joined(separator: "\n"),
                       confidence: items.map(\.confidence).min() ?? 0)
    }
}
