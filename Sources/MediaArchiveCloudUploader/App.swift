import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

struct FileRow: Identifiable {
    var id: String { item.id }
    let item: AudioItem
    var status = "Not checked online"
    var detail = ""
    var bytes: Int64 = 0
    var failed = false
    var finished = false
    var existing = false
    var active = false
    var phase: TransferPhase = .checking
}

@MainActor final class UploadModel: ObservableObject {
    @Published var folder: URL?
    @Published var files: [URL] = []
    @Published var includeFolder = false
    @Published var simultaneousUploads = 2
    @Published var transferring = false
    @Published var transferSnapshot: TransferSnapshot?
    private var statistics: TransferStatistics?
    private var statisticsTask: Task<Void, Never>?
    private var fatalUploadError: String?
    private let storageOverride: (any ArchiveStorage)?
    @Published var buckets: [CloudBucket] = []
    @Published var discoveryMessage = "Sign in to see your Google Cloud buckets."
    @Published var manualProject = ""
    @Published var manualBucket = ""
    @Published var showGoogleSetup = false
    private var preferences = ArchivePreferences()
    private let preferencesFile: URL
    private let directory: CloudDirectory
    @Published var rows: [FileRow] = []
    @Published var excluded: [String] = []
    @Published var issues: [String] = []
    @Published var busy = false
    @Published var previewReady = false
    @Published var message = "Choose a bucket and recordings, then start uploading. Preview is optional."
    @Published var error: String?
    @Published var selection: String?
    @Published var activity = ""
    @Published var transferred: Int64 = 0
    @Published var started: Date?
    let login: GoogleLogin
    private var job: Task<Void, Never>?
    @Published var configuration: ArchiveConfiguration?
    private var storage: (any ArchiveStorage)?
    init(login: GoogleLogin? = nil, loadConfiguration: Bool = true,
         preferencesFile: URL = ArchivePreferences.savedFile, directoryHTTP: HTTPTransport = SecureHTTP(),
         storageOverride: (any ArchiveStorage)? = nil) {
        let account = login ?? GoogleLogin()
        self.login = account; self.preferencesFile = preferencesFile; self.storageOverride = storageOverride
        directory = CloudDirectory(http: directoryHTTP, token: { force in try await account.token(forceRefresh: force) })
        if loadConfiguration { restorePreferences() }
    }
    private func restorePreferences() {
        do {
            if let saved = try ArchivePreferences.load(from: preferencesFile) {
                preferences = saved
                folder = saved.sourceFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
                includeFolder = saved.includeFolder; simultaneousUploads = saved.simultaneousUploads ?? 2
                if let bucket = saved.bucket, !login.email.isEmpty, saved.accountEmail == login.email {
                    try applyConfiguration(ArchiveConfiguration(environment: ["BISCO_GCS_BUCKET": bucket,
                        "BISCO_SOURCE_FOLDER": saved.sourceFolder ?? ""]))
                }
            } else {
                // One-time upgrade from a previous imported configuration, if present.
                let env = ProcessInfo.processInfo.environment
                if env["BISCO_ENV_FILE"] != nil || env["BISCO_GCS_BUCKET"] != nil ||
                    FileManager.default.fileExists(atPath: ArchiveConfiguration.savedFile.path) {
                    try useLegacyConfiguration(ArchiveConfiguration.load())
                }
            }
        } catch { self.error = "Could not restore local settings: " + error.localizedDescription }
    }
    private func savePreferences(_ value: ArchivePreferences) throws {
        try value.save(to: preferencesFile)
        preferences = value
    }
    private func useLegacyConfiguration(_ value: ArchiveConfiguration) throws {
        let saved = ArchivePreferences(bucket: value.bucket, accountEmail: login.email.isEmpty ? nil : login.email,
                                       sourceFolder: value.sourceFolder?.path, simultaneousUploads: simultaneousUploads)
        try savePreferences(saved)
        files = []; includeFolder = false
        try applyConfiguration(value)
    }
    func selectBucket(_ name: String) {
        guard !busy, !login.email.isEmpty else { return }
        do {
            if name.isEmpty {
                var saved = preferences; saved.bucket = nil; saved.projectID = nil
                try savePreferences(saved)
                configuration = nil; storage = nil; invalidate(); return
            }
            let value = try ArchiveConfiguration(environment: ["BISCO_GCS_BUCKET": name,
                "BISCO_SOURCE_FOLDER": folder?.path ?? ""])
            var saved = preferences
            saved.bucket = value.bucket; saved.projectID = buckets.first { $0.name == name }?.projectID
            saved.accountEmail = login.email
            saved.sourceFolder = files.isEmpty ? folder?.path : nil
            try savePreferences(saved)
            try applyConfiguration(value)
        } catch { self.error = error.localizedDescription }
    }
    func rememberSource() {
        var saved = preferences
        saved.sourceFolder = files.isEmpty ? folder?.path : nil
        saved.includeFolder = includeFolder; saved.simultaneousUploads = simultaneousUploads
        do { try savePreferences(saved) }
        catch { self.error = "Could not save your selection: " + error.localizedDescription }
    }
    func clearAccountDestination() {
        buckets = []; configuration = nil; storage = nil; invalidate()
        preferences.bucket = nil; preferences.projectID = nil; preferences.accountEmail = nil
        do { try savePreferences(preferences) } catch { self.error = error.localizedDescription }
        discoveryMessage = "Sign in to see your Google Cloud buckets."
    }
    private func discoverBuckets(project: String? = nil) async throws {
        discoveryMessage = "Finding buckets…"
        let result: BucketDiscovery
        if let project {
            let found = try await directory.buckets(projectID: project)
            result = BucketDiscovery(buckets: found, warnings: [])
            buckets = Array(Dictionary((buckets + found).map { ($0.name, $0) }, uniquingKeysWith: { _, b in b }).values)
                .sorted { $0.name < $1.name }
        } else {
            result = try await directory.discover()
            buckets = result.buckets
        }
        try Task.checkCancellation()
        let summary = result.buckets.isEmpty ? "No buckets found. Use the options below if your account has limited listing access." :
            "Choose a bucket. Preview will check your access to the recordings."
        discoveryMessage = ([summary] + result.warnings).joined(separator: "\n")
    }
    func refreshBuckets(project: String? = nil) {
        guard !busy, !login.email.isEmpty else { return }
        busy = true
        job = Task {
            defer { busy = false; job = nil }
            do { try await discoverBuckets(project: project) }
            catch is CancellationError { discoveryMessage = "Bucket search cancelled. Refresh to try again." }
            catch { discoveryMessage = discoveryError(error) }
        }
    }
    private func discoveryError(_ error: Error) -> String {
        if (error as? ServiceFailure)?.status == 403 {
            return "Google denied bucket listing. Ask your administrator for permission to list buckets in this project, or enter a known bucket below."
        }
        return error.localizedDescription
    }
    func applyConfiguration(_ value: ArchiveConfiguration) throws {
        let client: any ArchiveStorage
        if let storageOverride { client = storageOverride }
        else {
            client = try StorageClient(bucket: value.bucket, store: KeychainStore(), token: { [login] force in
                try await login.token(forceRefresh: force)
            })
        }
        configuration = value; storage = client; folder = value.sourceFolder
        invalidate(); message = "Choose or review your recordings, then start uploading. Preview is optional."
    }
    func reloadConfiguration() {
        do { try useLegacyConfiguration(ArchiveConfiguration.load()) }
        catch { self.error = error.localizedDescription }
    }
    func importEnvironment() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the local .env file supplied by your archive administrator. It sets the destination bucket and optional source folder."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ArchiveConfiguration.saveImported(LocalInput.text(url))
                reloadConfiguration()
            } catch { self.error = error.localizedDescription }
        }
    }
    var canExportReport: Bool { !rows.isEmpty || !excluded.isEmpty || !issues.isEmpty }
    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.item.size } }
    var accountedBytes: Int64 { rows.reduce(0) { $0 + ($1.finished ? $1.item.size : $1.bytes) } }
    var finishedCount: Int { rows.filter(\.finished).count }
    var failedCount: Int { rows.filter(\.failed).count }
    var selectedRow: FileRow? { rows.first { $0.id == selection } }
    var destination: String {
        guard let configuration else { return "Choose a destination bucket above" }
        return "gs://\(configuration.bucket)/" + (includeFolder && files.isEmpty ? (folder?.lastPathComponent ?? "Selected folder") + "/" : "")
    }
    func invalidate() {
        rows = []; excluded = []; issues = []; previewReady = false; activity = ""; started = nil; transferred = 0
        statisticsTask?.cancel(); statisticsTask = nil; statistics = nil; transferSnapshot = nil
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose archive folder"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url; files = []; invalidate(); rememberSource(); message = "Ready to upload. You can also preview without uploading."
        }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.prompt = "Choose recordings"
        panel.message = "Select recordings from one folder. Their filenames will go directly into the bucket."
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            files = panel.urls; folder = nil; includeFolder = false
            invalidate(); rememberSource(); message = "Ready to upload. You can also preview without uploading."
        }
    }
    var sourceDescription: String {
        files.isEmpty ? (folder?.path ?? "Choose a folder or individual recordings") :
            "\(files.count) selected file(s) in \(files.first!.deletingLastPathComponent().path)"
    }
    func importClient(connectAfterImport: Bool = false) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose the Desktop app OAuth JSON configuration supplied by your archive administrator."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try login.importClient(url); clearAccountDestination(); showGoogleSetup = false
                message = "Google setup imported. Sign in with your own account."
                if connectAfterImport { signIn() }
            }
            catch { showGoogleSetup = false; self.error = error.localizedDescription }
        }
    }
    func signIn() {
        guard !busy else { return }
        guard login.configured else { showGoogleSetup = true; return }
        busy = true
        job = Task {
            defer { busy = false; job = nil }
            do {
                try await login.signIn()
                if preferences.accountEmail != login.email { clearAccountDestination() }
                invalidate(); message = "Signed in. Choose your destination bucket and recordings."
                do { try await discoverBuckets() }
                catch is CancellationError { discoveryMessage = "Bucket search cancelled. Refresh to try again." }
                catch { discoveryMessage = discoveryError(error) }
            }
            catch is CancellationError { message = "Login cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
    func signOut() {
        clearAccountDestination()
        do { try login.signOut(); message = "Signed out on this Mac." }
        catch { self.error = error.localizedDescription }
    }
    var canStart: Bool {
        !busy && configuration != nil && !login.email.isEmpty && (folder != nil || !files.isEmpty)
    }
    var remainingBytes: Int64 {
        rows.reduce(0) { $0 + ($1.finished || $1.existing ? 0 : max(0, $1.item.size - $1.bytes)) }
    }
    var activeCount: Int { rows.filter(\.active).count }
    var skippedCount: Int { rows.filter { $0.finished && $0.existing }.count }
    var speedText: String {
        guard transferring else { return "—" }
        guard let rate = transferSnapshot?.bytesPerSecond else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(rate, Double(Int64.max / 2))), countStyle: .file) + "/s"
    }
    var remainingTimeText: String {
        guard transferring else { return started != nil && !rows.isEmpty && rows.allSatisfy(\.finished) ? "Finished" : "—" }
        let active = rows.filter(\.active)
        if !active.isEmpty && active.allSatisfy({ $0.phase == .retrying }) { return "Retrying…" }
        if !active.isEmpty && active.allSatisfy({ $0.phase == .checking }) { return "Checking files…" }
        if remainingBytes == 0 { return "Finishing…" }
        guard let seconds = transferSnapshot?.remainingSeconds, seconds.isFinite else { return "Calculating…" }
        if seconds < 60 { return "About < 1 min" }
        if seconds > 365 * 86400 { return "Over 1 year" }
        let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated; formatter.maximumUnitCount = 2
        return "About " + (formatter.string(from: min(seconds, 365 * 86400)) ?? "—")
    }
    private func prepare() async throws {
        let sourceFolder = folder, sourceFiles = files, include = includeFolder
        invalidate(); message = "Scanning audio files…"
        let scan = Task.detached(priority: .userInitiated) {
            if !sourceFiles.isEmpty { return try AudioScanner.scan(files: sourceFiles) }
            guard let sourceFolder else { throw ArchiveError("Choose your recordings first.") }
            return try AudioScanner.scan(folder: sourceFolder, includeFolder: include)
        }
        let report = try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
        try Task.checkCancellation()
        rows = report.items.map { FileRow(item: $0) }; excluded = report.excluded; issues = report.issues
        if !login.email.isEmpty, let storage {
            message = "Checking existing files…"
            // Keep preparation read-only and stop on a global permission problem.
            for index in rows.indices {
                try Task.checkCancellation()
                activity = "Checking \(index + 1) of \(rows.count): \(rows[index].item.objectName)"
                do {
                    let present = try await storage.exists(rows[index].item)
                    rows[index].existing = present
                    rows[index].status = present ? "Will skip — exists" : "Ready to upload"
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    rows[index].status = "Check failed"; rows[index].failed = true
                    rows[index].detail = error.localizedDescription
                    if error is AuthenticationFailure { throw error }
                    if let failure = error as? ServiceFailure, [401, 403].contains(failure.status) { throw error }
                }
            }
        }
        try Task.checkCancellation()
        previewReady = true
    }
    func preview() {
        guard !busy, folder != nil || !files.isEmpty else { return }
        busy = true; error = nil
        job = Task {
            defer { busy = false; job = nil; activity = "" }
            do {
                try await prepare()
                message = login.email.isEmpty || storage == nil ? "Local preview complete. Sign in and choose a bucket to upload." :
                    "Dry run complete. No files uploaded. \(rows.filter(\.existing).count) already exist."
            } catch is CancellationError { message = "Preview cancelled. Start upload will prepare your files again." }
            catch { self.error = error.localizedDescription; message = "Preview stopped. Resolve the error and try again." }
        }
    }
    func upload() {
        guard canStart, let storage else { return }
        busy = true; error = nil; fatalUploadError = nil
        let limit = simultaneousUploads
        job = Task {
            let wake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Uploading archive audio")
            defer {
                ProcessInfo.processInfo.endActivity(wake)
                statisticsTask?.cancel(); statisticsTask = nil; sampleStatistics()
                transferring = false; busy = false; activity = ""; job = nil
            }
            do {
                if !previewReady || rows.isEmpty || rows.allSatisfy(\.finished) { try await prepare() }
                try Task.checkCancellation()
                guard issues.isEmpty, !rows.contains(where: { $0.failed && $0.status == "Check failed" }) else {
                    previewReady = false
                    throw ArchiveError("Preparation found unreadable paths or failed cloud checks. Review the report and fix them before starting again. No new uploads were started.")
                }
                guard !rows.isEmpty else { message = "No eligible audio files found. Nothing uploaded."; return }
                transferring = true; started = Date(); transferred = 0; statistics = TransferStatistics()
                message = "Uploading with up to \(limit) simultaneous files…"
                startStatistics()
                let pending = rows.indices.filter { !rows[$0].finished }
                try await BoundedWork.run(pending, limit: limit) { [self] index in
                    try await self.uploadFile(index: index, storage: storage)
                }
                if rows.allSatisfy(\.finished) { message = "Finished. \(finishedCount) files uploaded or safely skipped." }
                else { message = "Stopped with \(failedCount) file errors. Select a row for details, then Retry / Resume." }
            } catch {
                if let fatalUploadError {
                    self.error = fatalUploadError; message = "Uploads stopped. Resolve the account or permission error, then retry."
                } else if Task.isCancelled || error is CancellationError {
                    message = "Cancelled. Completed files are safe; Start or Retry / Resume continues unfinished files."
                } else {
                    self.error = error.localizedDescription; message = "Stopped. Resolve the error and try again."
                }
            }
        }
    }
    private func uploadFile(index: Int, storage: any ArchiveStorage) async throws {
        try Task.checkCancellation()
        guard fatalUploadError == nil else { throw CancellationError() }
        rows[index].failed = false; rows[index].detail = ""; rows[index].bytes = 0
        rows[index].status = "Checking destination…"; rows[index].active = true; rows[index].phase = .checking
        let item = rows[index].item
        defer { rows[index].active = false; sampleStatistics() }
        do {
            let result = try await storage.upload(item, statistics: statistics) { [self] update in
                await self.update(index: index, progress: update)
            }
            rows[index].status = result.rawValue; rows[index].finished = true; rows[index].existing = result == .existing
            if result == .existing { rows[index].detail = "An object with this name already exists. It was not changed or compared for audio equivalence." }
        } catch {
            if Task.isCancelled || error is CancellationError {
                rows[index].status = "Paused — resume available"; throw CancellationError()
            }
            rows[index].failed = true; rows[index].status = "Needs retry"; rows[index].detail = error.localizedDescription
            if error is AuthenticationFailure || (error as? ServiceFailure).map({ [401, 403].contains($0.status) }) == true {
                fatalUploadError = error.localizedDescription; login.cancel(); throw error
            }
        }
    }
    private func update(index: Int, progress: UploadProgress) {
        guard rows.indices.contains(index) else { return }
        statistics?.confirm(progress.newBytes)
        rows[index].bytes = progress.bytes; rows[index].status = progress.message; rows[index].phase = progress.phase
        rows[index].existing = false
    }
    private func startStatistics() {
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleStatistics()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }
    private func sampleStatistics() {
        guard let statistics else { return }
        transferSnapshot = statistics.snapshot(remainingBytes: remainingBytes)
        transferred = transferSnapshot?.sentBytes ?? 0
        activity = "\(activeCount) active · \(skippedCount) skipped · " + ByteCountFormatter.string(fromByteCount: remainingBytes, countStyle: .file) + " remaining"
    }
    func waitForIdle() async { await job?.value }
    func cancel() { job?.cancel(); login.cancel(); message = "Cancelling…" }
    func exportReport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Media-Archive-upload-report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "Media Archive Cloud Uploader\n\(Date().formatted())\nSource: \(sourceDescription)\nDestination: \(destination)\n\(message)\n\n"
        for row in rows { text += "\(row.status)\t\(row.item.objectName)\t\(row.item.size) bytes\n\(row.detail.isEmpty ? "" : row.detail + "\n")" }
        text += "\nEXCLUDED\n" + excluded.joined(separator: "\n")
        text += "\n\nSCAN ISSUES\n" + issues.joined(separator: "\n") + "\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}

struct LoginBar: View {
    @ObservedObject var model: UploadModel
    @ObservedObject var login: GoogleLogin
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: login.email.isEmpty ? "person.crop.circle" : "checkmark.shield.fill")
                .foregroundStyle(login.email.isEmpty ? Color.secondary : Color.teal).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(login.email.isEmpty ? "Connect your Google account" : login.email).fontWeight(.medium)
                if let issue = login.storageIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                Text(login.configured ? "Your account · credentials stored in macOS Keychain" : "Sign in to begin · guided setup on first use")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Setup") {
                Button("Import Google client JSON…") { model.importClient() }
                Menu("Advanced") {
                    Button("Import environment configuration (.env)…", action: model.importEnvironment)
                    Button("Reload environment configuration", action: model.reloadConfiguration)
                }
                Button("Google account permissions…") { NSWorkspace.shared.open(URL(string: "https://myaccount.google.com/connections")!) }
            }.fixedSize().disabled(model.busy)
            if login.email.isEmpty {
                Button("Sign in with Google", action: model.signIn).disabled(model.busy)
            } else { Button("Sign out", action: model.signOut).disabled(model.busy) }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct GoogleSetupView: View {
    @ObservedObject var model: UploadModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Media Archive Cloud Uploader to Google").font(.title2).bold()
            Text("Google needs to recognize this app before it can open your account sign-in. This is a one-time setup on this Mac.")
            Text("Your archive administrator can supply a Desktop app OAuth JSON file. If you manage the Google Cloud project, create a Desktop app client in Google Auth Platform and download its JSON.")
            Link("Open Google Auth Platform", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
            Text("This file identifies the app. You will enter your Google password only in your browser. Your account login is stored in macOS Keychain.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.showGoogleSetup = false }
                Spacer()
                Button("Choose Google configuration & sign in…") { model.importClient(connectAfterImport: true) }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 540)
    }
}

struct DestinationPicker: View {
    @ObservedObject var model: UploadModel
    @ObservedObject var login: GoogleLogin
    @State private var showFallback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Destination bucket", selection: Binding(get: { model.configuration?.bucket ?? "" }, set: model.selectBucket)) {
                    Text("Choose a bucket…").tag("")
                    if let saved = model.configuration?.bucket, !model.buckets.contains(where: { $0.name == saved }) {
                        Text(saved + " (saved selection)").tag(saved)
                    }
                    ForEach(model.buckets) { bucket in Text(bucket.name + " — " + bucket.projectID).tag(bucket.name) }
                }.disabled(model.busy || login.email.isEmpty)
                Button("Refresh") { model.refreshBuckets() }.disabled(model.busy || login.email.isEmpty)
            }
            ScrollView { Text(model.discoveryMessage).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(height: model.discoveryMessage.contains("\n") ? 45 : 28)
            Button("Can’t find your bucket?") { showFallback = true }
            .popover(isPresented: $showFallback) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Find a destination").font(.headline)
                    Text("Some accounts can upload but cannot list projects or buckets. Enter a project ID to look there, or use a known bucket name.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Google Cloud project ID", text: $model.manualProject)
                        Button("Find buckets") { model.refreshBuckets(project: model.manualProject) }.disabled(model.manualProject.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack {
                        TextField("Bucket name (without gs://)", text: $model.manualBucket)
                        Button("Use bucket") { model.selectBucket(model.manualBucket.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .disabled(model.manualBucket.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Done") { showFallback = false }.frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(20).frame(width: 500).disabled(model.busy || login.email.isEmpty)
            }.font(.callout).disabled(model.busy || login.email.isEmpty)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: UploadModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 48)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Media Archive Cloud Uploader").font(.system(size: 27, weight: .bold))
                    Text("AUDIO ARCHIVE").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Never overwrite", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            LoginBar(model: model, login: model.login)
            DestinationPicker(model: model, login: model.login)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Recordings", systemImage: "folder").font(.headline)
                    Spacer()
                    Button("Choose files…", action: model.chooseFiles).disabled(model.busy)
                    Button("Choose folder…", action: model.chooseFolder).disabled(model.busy)
                }
                Text(model.sourceDescription)
                    .foregroundStyle(model.folder == nil && model.files.isEmpty ? .secondary : .primary).lineLimit(2).textSelection(.enabled)
                HStack {
                    Toggle("Include selected folder name", isOn: $model.includeFolder)
                        .disabled(model.busy || !model.files.isEmpty).onChange(of: model.includeFolder) { _ in model.invalidate(); model.rememberSource() }
                    Spacer()
                    Picker("Simultaneous uploads", selection: $model.simultaneousUploads) {
                        Text("1").tag(1); Text("2").tag(2); Text("4").tag(4)
                    }.fixedSize().disabled(model.busy)
                        .onChange(of: model.simultaneousUploads) { _ in model.rememberSource() }
                }
                Text(model.destination).font(.system(.caption, design: .monospaced)).foregroundStyle(.teal).textSelection(.enabled)
                Text("FLAC · WAV · MP3 only. Hidden files, AppleDouble, REAPER files and symbolic links are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 25) {
                metric("AUDIO FILES", value: "\(model.rows.count)")
                metric("TOTAL SIZE", value: bytes(model.totalBytes))
                metric("EXCLUDED", value: "\(model.excluded.count)")
                metric("FINISHED", value: "\(model.finishedCount) / \(model.rows.count)")
                Spacer()
                if !model.issues.isEmpty { Label("\(model.issues.count) scan issues", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            }
            Table(model.rows, selection: $model.selection) {
                TableColumn("Destination path") { row in Text(row.item.objectName).lineLimit(1).help(row.item.objectName) }.width(min: 240)
                TableColumn("Size") { row in Text(bytes(row.item.size)).monospacedDigit() }.width(85)
                TableColumn("Status") { row in Text(row.status).foregroundStyle(row.failed ? Color.orange : row.finished ? Color.teal : Color.primary).help(row.detail) }.width(min: 180)
            }.frame(minHeight: 120)
            if let row = model.selectedRow, !row.detail.isEmpty {
                Text(row.detail).font(.caption).foregroundStyle(row.failed ? .orange : .secondary).textSelection(.enabled)
            }
            if !model.issues.isEmpty {
                Text("Some paths could not be scanned. Export the report to review them before considering this archive complete.")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 7) {
                if model.started != nil {
                    HStack(spacing: 24) {
                        Label(model.speedText, systemImage: "speedometer").monospacedDigit()
                        Label(model.remainingTimeText, systemImage: "clock").monospacedDigit()
                        Spacer()
                        Text("\(bytes(model.transferred)) sent this run").font(.caption).foregroundStyle(.secondary)
                    }.font(.headline)
                }
                ProgressView(value: Double(model.accountedBytes), total: Double(max(1, model.totalBytes))).tint(.teal)
                HStack {
                    Text(model.message).font(.callout)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if !model.activity.isEmpty { Text(model.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if model.started != nil {
                    Text("\(bytes(model.accountedBytes)) accounted for · existing objects count as finished · time remaining is an estimate")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Export report…", action: model.exportReport).disabled(!model.canExportReport || model.busy)
                Spacer()
                if model.busy {
                    Button("Cancel", role: .cancel, action: model.cancel).keyboardShortcut(.cancelAction)
                } else {
                    Button("Preview (dry run)", action: model.preview).disabled(model.folder == nil && model.files.isEmpty)
                    Button(model.started == nil || model.rows.allSatisfy(\.finished) ? "Start upload" : "Retry / Resume", action: model.upload)
                        .buttonStyle(.borderedProminent).tint(.teal)
                        .disabled(!model.canStart)
                }
            }
        }.padding(24).frame(minWidth: 850, minHeight: 750)
        .task { if !model.login.email.isEmpty { model.refreshBuckets() } }
        .sheet(isPresented: $model.showGoogleSetup) { GoogleSetupView(model: model) }
        .alert("Media Archive Cloud Uploader", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct MediaArchiveCloudUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = UploadModel()
    var body: some Scene {
        Window("Media Archive Cloud Uploader", id: "main") { ContentView(model: model) }
            .defaultSize(width: 1000, height: 870)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
