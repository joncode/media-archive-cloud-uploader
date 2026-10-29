import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BiscoCore

struct FileRow: Identifiable {
    var id: String { item.id }
    let item: AudioItem
    var status = "Not checked online"
    var detail = ""
    var bytes: Int64 = 0
    var failed = false
    var finished = false
}

@MainActor final class UploadModel: ObservableObject {
    @Published var folder: URL?
    @Published var includeFolder = false
    @Published var rows: [FileRow] = []
    @Published var excluded: [String] = []
    @Published var issues: [String] = []
    @Published var busy = false
    @Published var previewReady = false
    @Published var message = "Choose a folder, preview the recordings, then upload."
    @Published var error: String?
    @Published var selection: String?
    @Published var activity = ""
    @Published var transferred: Int64 = 0
    @Published var started: Date?
    let login = GoogleLogin()
    private var job: Task<Void, Never>?
    @Published var configuration: ArchiveConfiguration?
    private var storage: StorageClient?
    init() { reloadConfiguration() }
    func reloadConfiguration() {
        do {
            let value = try ArchiveConfiguration.load()
            let client = try StorageClient(bucket: value.bucket, store: KeychainStore(), token: { [login] force in
                try await login.token(forceRefresh: force)
            })
            configuration = value; storage = client; folder = value.sourceFolder
            invalidate(); message = "Choose or review the source folder, then preview."
        } catch {
            configuration = nil; storage = nil; folder = nil; invalidate()
            message = error.localizedDescription
        }
    }
    func importEnvironment() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the local .env file supplied by your archive administrator. It sets the destination bucket and optional source folder."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ArchiveConfiguration.saveImported(String(contentsOf: url, encoding: .utf8))
                reloadConfiguration()
            } catch { self.error = error.localizedDescription }
        }
    }
    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.item.size } }
    var accountedBytes: Int64 { rows.reduce(0) { $0 + ($1.finished ? $1.item.size : $1.bytes) } }
    var finishedCount: Int { rows.filter(\.finished).count }
    var failedCount: Int { rows.filter(\.failed).count }
    var selectedRow: FileRow? { rows.first { $0.id == selection } }
    var destination: String {
        guard let configuration else { return "Destination not configured — import a local .env file in Setup" }
        return "gs://\(configuration.bucket)/" + (includeFolder ? (folder?.lastPathComponent ?? "Selected folder") + "/" : "")
    }
    func invalidate() { rows = []; excluded = []; issues = []; previewReady = false; activity = ""; started = nil; transferred = 0 }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose archive folder"
        if panel.runModal() == .OK, let url = panel.url { folder = url; invalidate(); message = "Ready for a dry-run preview." }
    }
    func importClient() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose the Desktop app OAuth JSON configuration supplied by your archive administrator."
        if panel.runModal() == .OK, let url = panel.url {
            do { try login.importClient(url); invalidate(); message = "Google setup imported. Sign in with your own account." }
            catch { self.error = error.localizedDescription }
        }
    }
    func signIn() {
        busy = true
        job = Task {
            defer { busy = false; job = nil }
            do { try await login.signIn(); invalidate(); message = "Signed in. Choose a folder and preview." }
            catch is CancellationError { message = "Login cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
    func signOut() {
        do { try login.signOut(); invalidate(); message = "Signed out on this Mac." }
        catch { self.error = error.localizedDescription }
    }
    func preview() {
        guard let folder else { return }
        invalidate(); busy = true; message = "Scanning audio files…"
        let include = includeFolder
        job = Task {
            defer { busy = false; job = nil; activity = "" }
            do {
                let scan = Task.detached(priority: .userInitiated) { try AudioScanner.scan(folder: folder, includeFolder: include) }
                let report = try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
                try Task.checkCancellation()
                rows = report.items.map { FileRow(item: $0) }; excluded = report.excluded; issues = report.issues
                if !login.email.isEmpty, let storage {
                    for index in rows.indices {
                        try Task.checkCancellation()
                        activity = "Checking \(index + 1) of \(rows.count): \(rows[index].item.objectName)"
                        do {
                            let present = try await storage.exists(rows[index].item)
                            rows[index].status = present ? "Will skip — exists" : "Ready to upload"
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            rows[index].status = "Check failed"; rows[index].failed = true
                            rows[index].detail = error.localizedDescription
                            // A global authorization problem should not trigger thousands of repeated requests.
                            if let failure = error as? ServiceFailure, [401, 403].contains(failure.status) { throw error }
                        }
                    }
                    message = "Dry run complete. No files uploaded. \(rows.filter { $0.status == "Will skip — exists" }.count) already exist."
                } else {
                    message = "Local preview complete. Configure a destination, sign in, and preview again to check cloud files."
                }
                previewReady = true
            } catch is CancellationError { message = "Preview cancelled. Run Preview again before uploading." }
            catch { self.error = error.localizedDescription; message = "Preview stopped. Resolve the error and preview again." }
        }
    }
    func upload() {
        guard previewReady, !login.email.isEmpty, let storage else { return }
        busy = true; transferred = 0; started = Date(); message = "Uploading to the archive…"
        job = Task {
            let wake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Uploading archive audio")
            defer { ProcessInfo.processInfo.endActivity(wake); busy = false; activity = ""; job = nil }
            for index in rows.indices where !rows[index].finished {
                if Task.isCancelled { break }
                rows[index].failed = false; rows[index].detail = ""; rows[index].bytes = 0
                rows[index].status = "Checking destination…"
                let item = rows[index].item
                activity = item.objectName
                do {
                    let result = try await storage.upload(item) { [self] update in
                        await self.update(index: index, progress: update)
                    }
                    rows[index].status = result.rawValue; rows[index].finished = true
                    if result == .existing { rows[index].detail = "An object with this name already exists. It was not changed or compared for audio equivalence." }
                } catch {
                    if Task.isCancelled { rows[index].status = "Paused — resume available"; break }
                    rows[index].failed = true; rows[index].status = "Needs retry"
                    rows[index].detail = error.localizedDescription
                    if let failure = error as? ServiceFailure, [401, 403].contains(failure.status) { self.error = error.localizedDescription; break }
                }
            }
            if Task.isCancelled { message = "Cancelled. Completed files are safe. Retry / Resume continues unfinished files." }
            else if rows.allSatisfy(\.finished) { message = "Finished. \(finishedCount) files uploaded or safely skipped." }
            else { message = "Stopped with \(failedCount) file errors. Select a row for details, then Retry / Resume." }
        }
    }
    private func update(index: Int, progress: UploadProgress) {
        guard rows.indices.contains(index) else { return }
        transferred += max(0, progress.bytes - rows[index].bytes)
        rows[index].bytes = progress.bytes; rows[index].status = progress.message
    }
    func cancel() { job?.cancel(); login.cancel(); message = "Cancelling…" }
    func exportReport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Bisco-upload-report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "Bisco Archive Uploader\n\(Date().formatted())\nSource: \(folder?.path ?? "")\nDestination: \(destination)\n\(message)\n\n"
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
                Text(login.configured ? "Your account · credentials stored in macOS Keychain" : "One-time setup: import your Google Desktop app configuration")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Setup") {
                Button("Import environment configuration (.env)…", action: model.importEnvironment)
                Button("Reload environment configuration", action: model.reloadConfiguration)
                Divider()
                Button("Import Google client JSON…", action: model.importClient)
                Button("Google account permissions…") { NSWorkspace.shared.open(URL(string: "https://myaccount.google.com/connections")!) }
            }.fixedSize().disabled(model.busy)
            if login.email.isEmpty {
                Button("Sign in with Google", action: model.signIn).disabled(!login.configured || model.busy)
            } else { Button("Sign out", action: model.signOut).disabled(model.busy) }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ContentView: View {
    @ObservedObject var model: UploadModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 48)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bisco Archive Uploader").font(.system(size: 27, weight: .bold))
                    Text("AUDIO ARCHIVE").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Never overwrite", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            LoginBar(model: model, login: model.login)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Source folder", systemImage: "folder").font(.headline)
                    Spacer()
                    Button("Choose folder…", action: model.chooseFolder).disabled(model.busy)
                }
                Text(model.folder?.path ?? "Select a concert folder or the drive’s archive folder")
                    .foregroundStyle(model.folder == nil ? .secondary : .primary).lineLimit(2).textSelection(.enabled)
                Toggle("Include selected folder name", isOn: $model.includeFolder)
                    .disabled(model.busy).onChange(of: model.includeFolder) { _ in model.invalidate() }
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
            }.frame(minHeight: 180)
            if let row = model.selectedRow, !row.detail.isEmpty {
                Text(row.detail).font(.caption).foregroundStyle(row.failed ? .orange : .secondary).textSelection(.enabled)
            }
            if !model.issues.isEmpty {
                Text("Some paths could not be scanned. Export the report to review them before considering this archive complete.")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: Double(model.accountedBytes), total: Double(max(1, model.totalBytes))).tint(.teal)
                HStack {
                    Text(model.message).font(.callout)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if !model.activity.isEmpty { Text(model.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if model.started != nil {
                    Text("\(bytes(model.accountedBytes)) accounted for · existing objects count as finished · progress updates after each 8 MiB chunk")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Export report…", action: model.exportReport).disabled(model.rows.isEmpty || model.busy)
                Spacer()
                if model.busy {
                    Button("Cancel", role: .cancel, action: model.cancel).keyboardShortcut(.cancelAction)
                } else {
                    Button("Preview (dry run)", action: model.preview).disabled(model.folder == nil)
                    Button(model.started == nil ? "Start upload" : "Retry / Resume", action: model.upload)
                        .buttonStyle(.borderedProminent).tint(.teal)
                        .disabled(model.configuration == nil || !model.previewReady || model.rows.isEmpty || model.login.email.isEmpty || model.rows.allSatisfy(\.finished))
                }
            }
        }.padding(24).frame(minWidth: 850, minHeight: 750)
        .alert("Bisco Archive Uploader", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
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

@main struct BiscoArchiveUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = UploadModel()
    var body: some Scene {
        Window("Bisco Archive Uploader", id: "main") { ContentView(model: model) }
            .defaultSize(width: 1000, height: 820)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
