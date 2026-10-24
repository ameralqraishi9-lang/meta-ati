import SwiftUI
import PhotosUI
import MetaStudyCore

@MainActor
struct StudyView: View {
    @StateObject private var glasses = MetaGlassesController()
    @StateObject private var study = StudyController()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("geminiModel") private var model = GeminiStudyClient.defaultModel
    @State private var permittedPractice = false
    @State private var settings = false
    @State private var source = "Glasses"
    @State private var photo: PhotosPickerItem?
    @State private var importedImage: UIImage?
    @State private var imageTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Look. Learn. Remember.").font(.largeTitle.bold())
                        Text("Automatic explanations for your practice questions.")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Question source", selection: $source) {
                        Text("Glasses").tag("Glasses")
                        Text("Practice image").tag("Practice image")
                    }.pickerStyle(.segmented).disabled(study.running)

                    if source == "Glasses" { glassesControls }
                    else {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Choose a practice image", systemImage: "photo")
                        }.buttonStyle(.bordered).disabled(study.running)
                    }
                    preview
                    VStack(alignment: .leading, spacing: 12) {
                        Label(study.running ? "Study is running" : "Study is paused",
                              systemImage: study.running ? "circle.fill" : "pause.circle")
                            .foregroundStyle(study.running ? .green : .secondary)
                        Text(study.status).font(.callout)
                        if study.isThinking { ProgressView() }
                        Toggle("I'm using permitted practice material", isOn: $permittedPractice)
                            .font(.callout).disabled(study.running)
                        Text("Recognized text is sent to Google Gemini using your API key. Images stay on your phone. API usage may cost money.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(study.running ? "Stop study" : "Start study") {
                            if study.running { stopStudy() }
                            else {
                                study.start(apiKey: KeychainStore.read(), model: model)
                                if study.running && source == "Practice image" { feedImportedImage() }
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(!study.running && (!permittedPractice || (source == "Glasses" ? !glasses.streaming : importedImage == nil)))
                        Toggle("Read explanations aloud", isOn: $study.speakAnswers)
                            .font(.callout)
                    }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    if let answer = study.answer {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(answer.heading).font(.title2.bold()).foregroundStyle(.mint)
                            Text(answer.conciseAnswer).font(.headline)
                            Text("Why").font(.headline)
                            Text(answer.rationale)
                            if !answer.mnemonic.isEmpty {
                                Text("Remember").font(.headline)
                                Text(answer.mnemonic)
                            }
                            Text("AI study support · check against your course material")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if !study.recognizedText.isEmpty {
                        DisclosureGroup("Check recognized text") {
                            Text(study.recognizedText).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Keep this app open while studying. Stop before switching apps. Works with clear, single-column English questions labeled A–D through A–F.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Meta Study").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.disabled(study.running) }
            .sheet(isPresented: $settings) { SettingsView(model: $model) }
            .alert("Glasses connection", isPresented: Binding(
                get: { glasses.errorMessage != nil },
                set: { if !$0 { glasses.errorMessage = nil } })) {
                Button("OK") { glasses.errorMessage = nil }
            } message: { Text(glasses.errorMessage ?? "") }
            .onOpenURL { url in Task { await glasses.handleURL(url) } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { stopStudy(); glasses.disconnect() }
            }
            .onChange(of: source) { _, _ in
                stopStudy()
                if source != "Glasses" { glasses.disconnect() }
            }
            .onChange(of: photo) { _, value in
                Task {
                    guard let data = try? await value?.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    importedImage = image
                }
            }
            .task {
                glasses.onFrame = { image, still in study.receive(image, isStill: still) }
                glasses.onUnavailable = { if source == "Glasses" { study.sourceUnavailable() } }
                study.onCard = { title, body in glasses.show(title, body: body) }
                study.onAnswer = { answer in glasses.show(answer) }
                study.onNewQuestion = { if source == "Glasses" { glasses.captureStill() } }
            }
        }.tint(.mint).preferredColorScheme(.dark)
    }

    private var glassesControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(glasses.deviceName, systemImage: "eyeglasses").font(.headline)
            Text(glasses.displayStatus).font(.caption).foregroundStyle(.secondary)
            if !glasses.registered {
                Button("Connect app in Meta AI") { Task { await glasses.register() } }
                    .buttonStyle(.bordered)
            } else {
                if !glasses.connected {
                    Text("Camera permission opens Meta AI for your approval.").font(.caption).foregroundStyle(.secondary)
                    Button("Allow glasses camera") { Task { await glasses.grantCamera() } }
                        .buttonStyle(.bordered)
                    Button(glasses.connecting ? "Connecting…" : "Connect camera and lens") {
                        Task { await glasses.connect() }
                    }.buttonStyle(.bordered).disabled(glasses.connecting)
                } else {
                    HStack {
                        Button("Capture still") { glasses.captureStill() }
                            .disabled(!glasses.streaming || !study.running)
                        Button("Disconnect") { stopStudy(); glasses.disconnect() }
                    }.buttonStyle(.bordered)
                }
            }
            if glasses.needsAppUpdate {
                Button("Update glasses app in Meta AI") { Task { await glasses.updateGlassesApp() } }
            }
            if glasses.needsFirmwareUpdate {
                Button("Update glasses firmware") { Task { await glasses.updateFirmware() } }
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06))
            if let image = source == "Glasses" ? glasses.preview : importedImage {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: source == "Glasses" ? "viewfinder" : "photo").font(.largeTitle)
                    Text("Keep the question and every answer choice visible").font(.caption)
                }.foregroundStyle(.secondary).padding()
            }
        }.frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func feedImportedImage() {
        imageTask?.cancel()
        imageTask = Task {
            while !Task.isCancelled, study.running, source == "Practice image", let image = importedImage {
                study.receive(image, isStill: true)
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    private func stopStudy() {
        imageTask?.cancel(); imageTask = nil
        study.stop()
    }
}

private struct SettingsView: View {
    @Binding var model: String
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Gemini account") {
                    SecureField("Gemini API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model ID", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("Get or manage your API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    Text("Your personal key is stored in the iPhone Keychain. It is never written to GitHub. Use a restricted key with a quota appropriate for study.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
                Section("About this build") {
                    Text("For authorized study sessions. Does not work inside other iPhone apps or bypass assessment restrictions.")
                    Text("Meta DAT 1.0.1 · iOS 17.2 or newer")
                }
            }.navigationTitle("Settings")
                .toolbar { Button("Save") {
                    do { try KeychainStore.save(key); dismiss() }
                    catch { problem = error.localizedDescription }
                }}
                .onAppear { key = KeychainStore.read() }
        }
    }
}
