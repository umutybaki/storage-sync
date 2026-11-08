import AppKit
import StorageSyncCore
import SwiftUI

/// The folder is the one choice that is not typed, so it gets a real target
/// instead of a label with a button stuck to the end of it.
struct FolderWell: View {
    let url: URL?
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: url == nil ? "folder.badge.plus" : "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? "No folder chosen")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(url?.deletingLastPathComponent().path(percentEncoded: false) ?? "Choose one, or drag a folder here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(url == nil ? "Choose…" : "Change…", action: choose)
        }
        .padding(.vertical, 4)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-6)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

/// Shared title block so both sheets start the same way.
struct SheetHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

/// Connection setup lives here once, rather than in every Create Sync form.
struct LocationEditorView: View {
    @ObservedObject var model: AppModel
    var onSave: (StorageLocation) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocationDraft
    @State private var isSaving = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    init(model: AppModel, kind: LocationKind = .cloud, onSave: @escaping (StorageLocation) -> Void = { _ in }) {
        _model = ObservedObject(wrappedValue: model)
        self.onSave = onSave
        var draft = LocationDraft()
        draft.kind = kind
        if let id = model.newSyncCredential ?? model.credentials.first?.id { draft.credentialChoice = .saved(id) }
        _draft = State(initialValue: draft)
    }

    private var requirement: String? {
        if !model.areLocationsAvailable { return "Waiting for the updated background agent…" }
        return draft.missingRequirement(existingCredentialNames: model.credentials.map(\.name), existingLocationNames: model.locations.map(\.name))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New Location", subtitle: "Save a folder or bucket to reuse in your syncs.")
            Divider()
            Form {
                Section {
                    Picker("Location", selection: $draft.kind) {
                        ForEach(LocationKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if draft.kind == .local {
                    Section("Folder on This Mac") {
                        FolderWell(url: draft.folderURL, isTargeted: isDropTargeted, choose: chooseFolder)
                        TextField("Name", text: $draft.name, prompt: Text(draft.folderURL?.lastPathComponent ?? "Same as the folder"))
                    }
                } else {
                    Section("Cloud Bucket") {
                        Picker("Provider", selection: $draft.provider) {
                            ForEach(StorageProvider.allCases) { Text($0.displayName).tag($0) }
                        }
                        if draft.provider == .cloudflareR2 {
                            TextField("Account ID", text: $draft.accountID, prompt: Text("Cloudflare account ID"))
                        } else {
                            if draft.provider == .compatible {
                                TextField("Endpoint", text: $draft.endpoint, prompt: Text("https://storage.example.com"))
                                    .textContentType(.URL)
                            }
                            TextField("Region", text: $draft.region, prompt: Text("us-east-1"))
                        }
                        TextField("Bucket", text: $draft.bucket, prompt: Text("my-bucket"))
                        TextField("Folder in Bucket", text: $draft.prefix, prompt: Text("Optional - whole bucket"))
                        TextField("Name", text: $draft.name, prompt: Text(draft.effectiveName.isEmpty ? "Same as the bucket" : draft.effectiveName))
                    }
                    Section {
                        if !model.credentials.isEmpty {
                            Picker("Use", selection: $draft.credentialChoice) {
                                ForEach(model.credentials) { credential in
                                    Text(credentialLabel(credential)).tag(CredentialChoice.saved(credential.id))
                                }
                                Divider()
                                Text("New Credentials…").tag(CredentialChoice.new)
                            }
                        }
                        if draft.isCreatingCredential {
                            TextField("Name", text: $draft.credentialName, prompt: Text(draft.provider.displayName))
                            CredentialKeyFields(accessKey: $draft.accessKey, secretKey: $draft.secretKey, sessionToken: $draft.sessionToken)
                        }
                    } header: { Text("Credentials") } footer: {
                        Text("Saved in your macOS Keychain. StorageSync checks access to this bucket before saving the location.")
                    }
                }
            }
            .formStyle(.grouped).disabled(isSaving)
            .dropDestination(for: URL.self) { urls, _ in
                guard !isSaving, let url = urls.first(where: { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }) else { return false }
                draft.kind = .local
                draft.folderURL = url
                return true
            } isTargeted: { isDropTargeted = $0 }
            Divider()
            HStack(spacing: 12) {
                Text(isSaving ? (draft.kind == .cloud ? "Checking the bucket…" : "Saving folder access…") : requirement ?? "Ready to save")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Save Location", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(requirement != nil || isSaving)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 580, height: draft.kind == .cloud ? 660 : 380)
        .alert("Couldn’t Save Location", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save as a reusable location."
        if panel.runModal() == .OK { draft.folderURL = panel.url }
    }

    private func credentialLabel(_ credential: StoredCredential) -> String {
        guard let summary = credential.accessKeySummary else { return credential.name }
        return "\(credential.name) — \(summary)"
    }

    private func save() {
        isSaving = true
        Task {
            do {
                let location = try await model.createLocation(draft)
                onSave(location)
                dismiss()
            } catch { errorMessage = error.localizedDescription; isSaving = false }
        }
    }
}

struct LocationDetailView: View {
    let location: StorageLocation
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var isRenaming = false
    @State private var errorMessage: String?

    private var dependents: [SyncJob] { model.syncsUsing(location) }

    var body: some View {
        Form {
            Section("Details") {
                LabeledContent("Type", value: location.localRoot != nil ? "Mac Folder" : "Cloud Bucket")
                LabeledContent("Location") {
                    Text(model.locationSummary(location)).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                if let id = location.connectionID, let connection = model.connections[id] {
                    LabeledContent("Provider", value: StorageProvider.identify(endpoint: connection.endpoint).displayName)
                    LabeledContent("Endpoint", value: connection.endpoint.absoluteString)
                    if let credential = model.credentials.first(where: { $0.keychainReference == connection.credentialReference }) {
                        LabeledContent("Credentials", value: credential.name)
                    }
                }
            }
            Section {
                if dependents.isEmpty {
                    Text("No syncs use this location yet.").foregroundStyle(.secondary)
                }
                ForEach(dependents) { job in
                    Button(job.name) { model.selection = .sync(job.id) }.buttonStyle(.link)
                }
                Button("Create Sync with This Location…") { model.beginCreatingSync(location: location) }
            } header: { Text("Used By") } footer: {
                Text("Removing a sync keeps this location. To change the folder or bucket, create a new location.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(location.name)
        .navigationSubtitle(location.localRoot != nil ? "Saved folder" : "Saved bucket")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename…") { name = location.name; isRenaming = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Remove Location…", role: .destructive) { model.locationPendingRemoval = location }
                    .disabled(!dependents.isEmpty)
            }
        }
        .alert("Rename Location", isPresented: $isRenaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    do { try await model.renameLocation(location, to: name) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("Every sync using this location keeps its current folder, bucket, and progress.") }
        .alert("Couldn’t Rename Location", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }
}
