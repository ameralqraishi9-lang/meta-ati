import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera
import MWDATDisplay
import MetaStudyCore

@MainActor
final class MetaGlassesController: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var deviceName = "No display glasses connected"
    @Published private(set) var available = false
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var streaming = false
    @Published private(set) var preview: UIImage?
    @Published private(set) var displayStatus = "Lens not connected"
    @Published var errorMessage: String?
    @Published private(set) var needsAppUpdate = false
    @Published private(set) var needsFirmwareUpdate = false

    var onFrame: ((UIImage, Bool) -> Void)?
    var onUnavailable: (() -> Void)?
    private let wearables = Wearables.shared
    private var selector: AutoDeviceSelector
    private var session: DeviceSession?
    private var camera: Camera?
    private var display: Display?
    private var displayStarted = false
    private var tokens: [AnyListenerToken] = []
    private var observationTasks: [Task<Void, Never>] = []
    private var timeoutTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var lastFrameAt: TimeInterval = 0
    private var sessionID = UUID()
    private var cardPages: [(String, String)] = []
    private var pageIndex = 0
    private var pendingCard: (String, String)?
    private var capturePending = false
    private var photoTimeoutTask: Task<Void, Never>?

    init() {
        selector = AutoDeviceSelector(wearables: Wearables.shared, filter: { $0.supportsDisplay() })
        registered = wearables.registrationState == .registered
        observationTasks.append(Task { [weak self, wearables] in
            for await state in wearables.registrationStateStream() {
                guard let self, !Task.isCancelled else { return }
                registered = state == .registered
                if !registered { disconnect() }
            }
        })
        observationTasks.append(Task { [weak self, wearables] in
            for await ids in wearables.devicesStream() {
                guard let self, !Task.isCancelled else { return }
                let devices = ids.compactMap { wearables.deviceForIdentifier($0) }.filter { $0.supportsDisplay() }
                available = !devices.isEmpty
                deviceName = devices.first?.nameOrId() ?? "No display glasses connected"
                needsFirmwareUpdate = devices.contains { $0.compatibility() == .deviceUpdateRequired }
            }
        })
    }

    func register() async {
        do { try await wearables.startRegistration() }
        catch { errorMessage = error.localizedDescription }
    }

    func grantCamera() async {
        do {
            guard try await wearables.requestPermission(.camera) == .granted else {
                errorMessage = "Camera access was not granted in Meta AI."
                return
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func handleURL(_ url: URL) async {
        guard url.scheme == "metatistudy",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        do { _ = try await wearables.handleUrl(url) }
        catch { errorMessage = error.localizedDescription }
    }

    func connect() async {
        guard session == nil, !connecting else { return }
        errorMessage = nil
        do {
            guard registered else { throw ConnectionError.message("Connect this app in Meta AI first.") }
            guard try await wearables.checkPermissionStatus(.camera) == .granted else {
                throw ConnectionError.message("Tap Allow glasses camera first. Meta AI will ask for access.")
            }
            guard let id = selector.activeDevice, let device = wearables.deviceForIdentifier(id),
                  device.linkState == .connected else {
                throw ConnectionError.message("Put on and unfold your paired display glasses, then reconnect.")
            }
            guard device.compatibility() == .compatible else {
                needsFirmwareUpdate = device.compatibility() == .deviceUpdateRequired
                throw ConnectionError.message("The glasses need a compatible firmware and Meta AI version.")
            }
            connecting = true
            needsAppUpdate = false
            let generation = UUID()
            sessionID = generation
            let newSession = try wearables.createSession(deviceSelector: selector)
            session = newSession
            tokens.append(newSession.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, sessionID == generation else { return }
                    switch state {
                    case .started:
                        connected = true
                        connecting = false
                        attachCapabilities(generation: generation)
                    case .paused:
                        streaming = false
                        onUnavailable?()
                    case .stopped:
                        disconnect()
                    case .stopping:
                        streaming = false
                        onUnavailable?()
                    default: break
                    }
                }
            })
            tokens.append(newSession.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, sessionID == generation else { return }
                    needsAppUpdate = error == .datAppOnTheGlassesUpdateRequired
                    errorMessage = error.localizedDescription
                    disconnect()
                }
            })
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, sessionID == generation, !displayStarted || !streaming else { return }
                errorMessage = "The camera or lens did not become ready. Check Meta AI and reconnect."
                disconnect()
            }
            try newSession.start()
        } catch {
            needsAppUpdate = (error as? DeviceSessionError) == .datAppOnTheGlassesUpdateRequired
            errorMessage = error.localizedDescription
            disconnect()
        }
    }

    private func attachCapabilities(generation: UUID) {
        guard let session, camera == nil else { return }
        do {
            guard let camera = try session.addCamera(config: StreamConfiguration(
                videoCodec: .raw, resolution: .high, frameRate: 7)) else {
                throw ConnectionError.message("The glasses camera could not start.")
            }
            self.camera = camera
            let stream = camera.stream
            tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
                guard let image = frame.makeUIImage() else { return }
                Task { @MainActor in
                    guard let self, sessionID == generation else { return }
                    lastFrameAt = ProcessInfo.processInfo.systemUptime
                    preview = image
                    onFrame?(image, false)
                }
            })
            tokens.append(stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, sessionID == generation else { return }
                    streaming = state == .streaming
                    if !streaming { onUnavailable?() }
                    finishReadinessIfReady()
                }
            })
            tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
                guard let image = UIImage(data: photo.data) else { return }
                Task { @MainActor in
                    guard let self, sessionID == generation, capturePending else { return }
                    capturePending = false
                    photoTimeoutTask?.cancel()
                    preview = image
                    onFrame?(image, true)
                }
            })
            tokens.append(stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, sessionID == generation else { return }
                    errorMessage = error.localizedDescription
                    onUnavailable?()
                }
            })
            let display = try session.addDisplay()
            self.display = display
            tokens.append(display.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, sessionID == generation else { return }
                    displayStarted = state == .started
                    displayStatus = displayStarted ? "Lens connected" : "Lens: \(state)"
                    if displayStarted { pumpDisplay() }
                    finishReadinessIfReady()
                }
            })
            display.start()
            stream.start()
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled, let self, sessionID == generation else { return }
                    if streaming && ProcessInfo.processInfo.systemUptime - lastFrameAt > 4 {
                        onUnavailable?()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            disconnect()
        }
    }

    private func finishReadinessIfReady() {
        if streaming && displayStarted { timeoutTask?.cancel(); timeoutTask = nil }
    }

    /// Stream stills are best-effort snapshots, not the experimental full-resolution Photo API.
    func captureStill() {
        guard streaming, !capturePending else { return }
        capturePending = true
        guard camera?.stream.capturePhoto(format: .jpeg) == true else {
            capturePending = false
            errorMessage = "A still could not be captured right now. Try again."
            return
        }
        photoTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, capturePending else { return }
            capturePending = false
            errorMessage = "Still capture timed out. Live recognition can continue."
        }
    }

    func show(_ title: String, body: String) {
        cardPages = [(title, body)]
        pageIndex = 0
        pendingCard = (title, body)
        pumpDisplay()
    }

    func show(_ answer: StudyAnswer) {
        cardPages = [(answer.heading, answer.conciseAnswer)]
        // Paginate at word boundaries to keep nursing rationales readable on the lens.
        var chunk = ""
        for word in answer.rationale.split(separator: " ") {
            if chunk.count + word.count > 260 && !chunk.isEmpty {
                cardPages.append(("Why", chunk)); chunk = ""
            }
            chunk += (chunk.isEmpty ? "" : " ") + word
        }
        if !chunk.isEmpty { cardPages.append(("Why", chunk)) }
        if !answer.mnemonic.isEmpty { cardPages.append(("Remember", answer.mnemonic)) }
        pageIndex = 0
        pendingCard = cardPages[0]
        pumpDisplay()
    }

    private func nextPage() {
        guard cardPages.count > 1 else { return }
        pageIndex = (pageIndex + 1) % cardPages.count
        pendingCard = cardPages[pageIndex]
        pumpDisplay()
    }

    /// Serial sends ensure an older answer cannot land after a newer status card.
    private func pumpDisplay() {
        guard displayStarted, sendTask == nil, pendingCard != nil else { return }
        let generation = sessionID
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == generation { sendTask = nil } }
            while !Task.isCancelled, sessionID == generation, displayStarted,
                  let display, let card = pendingCard {
                pendingCard = nil
                let hasPages = cardPages.count > 1
                do {
                    try await display.send(
                        FlexBox(direction: .column, spacing: 12) {
                            MWDATDisplay.Text(card.0, style: .heading)
                            MWDATDisplay.Text(card.1, style: .body)
                            if hasPages {
                                MWDATDisplay.Button(label: "Next", style: .primary, onClick: { [weak self] in
                                    Task { @MainActor in self?.nextPage() }
                                })
                            }
                        }.padding(24).background(.card)
                    )
                } catch {
                    guard sessionID == generation, !Task.isCancelled else { return }
                    displayStatus = "Lens delivery failed"
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateGlassesApp() async {
        do { try await wearables.openDATGlassesAppUpdate() }
        catch { errorMessage = error.localizedDescription }
    }

    func updateFirmware() async {
        do { try await wearables.openFirmwareUpdate() }
        catch { errorMessage = error.localizedDescription }
    }

    func disconnect() {
        sessionID = UUID()
        timeoutTask?.cancel(); timeoutTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        photoTimeoutTask?.cancel(); photoTimeoutTask = nil
        sendTask?.cancel(); sendTask = nil
        tokens.removeAll()
        display?.stop()
        camera?.stop()
        session?.stop()
        display = nil; camera = nil; session = nil
        displayStarted = false
        streaming = false; connected = false; connecting = false
        capturePending = false
        preview = nil
        cardPages = []; pendingCard = nil
        displayStatus = "Lens not connected"
        onUnavailable?()
    }

    private enum ConnectionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}
