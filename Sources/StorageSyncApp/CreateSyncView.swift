import AppKit
import StorageSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct CreateSyncView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SyncDraft
    @State private var isSaving = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    /// Opens on saved credentials whenever there are any — the ones the sheet
    /// was opened from, or failing that the first in the list. Reusing a saved
    /// set is the common case once a sync exists, and typing keys again for the
    /// same account is the mistake worth designing out.
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        var initial = SyncDraft()
        if let requested = model.newSyncCredential ?? model.credentials.first?.id {
            initial.credentialChoice = .saved(requested)
        }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Create Sync",
                subtitle: "Pick a folder and a bucket. StorageSync handles the rest."
            )

            Divider()

            Form {
                Section {
                    Picker("Copy", selection: $draft.direction) {
                        Text("This Mac → S3").tag(SyncDirection.upload)
                        Text("S3 → This Mac").tag(SyncDirection.download)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("Direction")
                } footer: {
                    Text(
                        draft.direction == .upload
                            ? "Back up a folder to S3. Files in the bucket are never removed."
                            : "Restore a bucket into a folder. Files in the folder are never removed."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Folder on This Mac") {
                    FolderWell(
                        url: draft.folderURL,
                        isTargeted: isDropTargeted,
                        choose: chooseFolder
                    )
                    TextField("Name", text: $draft.name, prompt: Text(draft.folderURL?.lastPathComponent ?? "Same as the folder"))
                }

                Section("S3 Bucket") {
                    Picker("Provider", selection: $draft.provider) {
                        ForEach(StorageProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    if draft.provider == .compatible {
                        TextField("Endpoint", text: $draft.endpoint, prompt: Text("https://storage.example.com"))
                            .textContentType(.URL)
                    }
                    TextField("Region", text: $draft.region, prompt: Text("us-east-1"))
                    TextField("Bucket", text: $draft.bucket, prompt: Text("my-bucket"))
                    TextField("Folder in bucket", text: $draft.prefix, prompt: Text("Optional"))
                }

                Section {
                    if !model.credentials.isEmpty {
                        Picker("Use", selection: $draft.credentialChoice) {
                            ForEach(model.credentials) { credential in
                                Text(credentialLabel(credential))
                                    .tag(CredentialChoice.saved(credential.id))
                            }
                            Divider()
                            Text("New Credentials…").tag(CredentialChoice.new)
                        }
                    }
                    if draft.isCreatingCredential {
                        if !model.credentials.isEmpty {
                            TextField(
                                "Name",
                                text: $draft.credentialName,
                                prompt: Text(draft.provider.rawValue)
                            )
                        }
                        CredentialKeyFields(
                            accessKey: $draft.accessKey,
                            secretKey: $draft.secretKey,
                            sessionToken: $draft.sessionToken
                        )
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            draft.isCreatingCredential
                                ? "Keys are tested once and then stored only in your macOS Keychain."
                                : "Saved in your macOS Keychain. StorageSync checks them against this bucket before starting.",
                            systemImage: "lock"
                        )
                        if draft.isCreatingCredential, !model.credentials.isEmpty {
                            Text("Saved credentials can be reused by any number of syncs, so keys only need typing once per account.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)
            // Dropping a folder anywhere on the sheet is faster than opening a
            // panel, and it is the gesture people already try first.
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first(where: isDirectory) else { return false }
                adopt(folder)
                return true
            } isTargeted: { isDropTargeted = $0 }

            Divider()

            footer
        }
        .frame(width: 580, height: 660)
        .onChange(of: draft.provider) { _, provider in
            if provider == .amazon, draft.endpoint.isEmpty {
                draft.endpoint = "https://s3.amazonaws.com"
            }
        }
        .alert("Couldn’t Create Sync", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            summary
            Spacer(minLength: 12)
            if isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button("Start Sync", action: start)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(missingRequirement != nil || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var missingRequirement: String? {
        draft.missingRequirement(existingCredentialNames: model.credentials.map(\.name))
    }

    /// Enough to tell two sets of keys for the same provider apart in a menu.
    private func credentialLabel(_ credential: StoredCredential) -> String {
        guard let summary = credential.accessKeySummary else { return credential.name }
        return "\(credential.name) — \(summary)"
    }

    /// Either what is still missing, or exactly what is about to happen.
    @ViewBuilder
    private var summary: some View {
        if isSaving {
            Text("Checking the bucket…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let missing = missingRequirement {
            Text(missing)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            Label(routePreview, systemImage: draft.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(routePreview)
        }
    }

    private var routePreview: String {
        let local = draft.effectiveName.isEmpty ? "This Mac" : draft.effectiveName
        let bucket = draft.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = SyncJob.normalizedPrefix(draft.prefix)
        let remote = prefix.isEmpty ? bucket : "\(bucket)/\(prefix)"
        return draft.direction == .upload ? "\(local) → \(remote)" : "\(remote) → \(local)"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func start() {
        isSaving = true
        Task {
            do {
                try await model.createSync(draft)
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = draft.direction == .upload
            ? "Choose the folder to back up."
            : "Choose the folder to restore into."
        if panel.runModal() == .OK, let url = panel.url {
            adopt(url)
        }
    }

    private func adopt(_ url: URL) {
        draft.folderURL = url
    }

    /// `URL.hasDirectoryPath` only reports the trailing slash, which a Finder
    /// drag does not always carry. Ask the filesystem instead.
    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

/// The folder is the one choice that is not typed, so it gets a real target
/// instead of a label with a button stuck to the end of it.
private struct FolderWell: View {
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
