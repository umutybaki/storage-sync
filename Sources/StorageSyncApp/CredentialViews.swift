import StorageSyncCore
import SwiftUI

// MARK: - Detail

/// One saved set of keys: what it is, which syncs depend on it, and the two
/// things you can do to it. The secret is never shown, because the app cannot
/// show what it does not keep — the keys live in the Keychain and are read by
/// the background agent at the moment a transfer needs them.
struct CredentialDetailView: View {
    let credential: StoredCredential
    @ObservedObject var model: AppModel

    private var dependents: [SyncJob] { model.syncsUsing(credential) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Access Key") {
                    Text(credential.accessKeySummary ?? "Stored in Keychain")
                        .monospaced(credential.accessKeySummary != nil)
                        .foregroundStyle(credential.accessKeySummary == nil ? .secondary : .primary)
                }
                LabeledContent("Secret Key") {
                    Text(verbatim: "••••••••••••")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hidden, stored in Keychain")
                }
                if credential.hasSessionToken {
                    LabeledContent("Session Token") {
                        Label("Temporary keys", systemImage: "clock.badge.exclamationmark")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Added", value: credential.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(
                    "Keys Updated",
                    value: credential.keysUpdatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            } header: {
                Text("Details")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "The keys are in your macOS Keychain. StorageSync stores only the name and the shortened access key you see here.",
                        systemImage: "lock"
                    )
                    if credential.hasSessionToken {
                        Label(
                            "Temporary credentials stop working when they expire. Replace them here and every sync below picks them up.",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }

            Section {
                if dependents.isEmpty {
                    Text("No syncs are using these credentials yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dependents) { job in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.name)
                                Text(SyncRoute.text(job, connection: model.connection(for: job)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: SyncRoute.symbol(job))
                        }
                    }
                }
                Button("Create Sync with These Credentials…") {
                    model.beginCreatingSync(using: credential)
                }
            } header: {
                Text("Used By")
            } footer: {
                if !dependents.isEmpty {
                    Text("Replacing the keys switches all of these over at once. Deleting is only possible once nothing is using them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(credential.name)
        .navigationSubtitle(credential.accessKeySummary ?? "Saved credentials")
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.beginEditingCredential(credential)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .help("Rename these credentials or replace their keys")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Create Sync with These Credentials…") {
                    model.beginCreatingSync(using: credential)
                }
                Divider()
                Button("Delete Credentials…", role: .destructive) {
                    model.requestRemoval(of: credential)
                }
                .disabled(!dependents.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help(
                dependents.isEmpty
                    ? "More actions"
                    : "\(dependents.count == 1 ? "One sync is" : "\(dependents.count) syncs are") using these credentials, so they cannot be deleted yet"
            )
        }
    }
}

// MARK: - Editor

/// Creates a set of credentials, renames one, or replaces the keys inside one.
///
/// Editing deliberately starts with the key fields empty rather than
/// pre-filled: StorageSync does not read the secret back to show it, so a
/// pre-filled field would have to be a lie or a Keychain prompt. Blank means
/// keep what is saved.
struct CredentialEditorView: View {
    let request: CredentialEditorRequest
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var sessionToken = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(request: CredentialEditorRequest, model: AppModel) {
        self.request = request
        _model = ObservedObject(wrappedValue: model)
        _name = State(initialValue: request.credential?.name ?? "")
    }

    private var existing: StoredCredential? { request.credential }
    private var isEditing: Bool { existing != nil }
    private var dependents: [SyncJob] { existing.map(model.syncsUsing) ?? [] }
    private var trimmedName: String { StoredCredential.normalizedName(name) }
    /// Any entry in the key fields at all means the user intends to replace the
    /// saved keys, so the form starts asking for a complete set.
    private var isReplacingKeys: Bool {
        !isEditing || !accessKey.trimmed.isEmpty || !secretKey.trimmed.isEmpty || !sessionToken.trimmed.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: isEditing ? "Edit Credentials" : "Add Credentials",
                subtitle: isEditing
                    ? "Rename these credentials, or replace their keys. Every sync using them switches over at once."
                    : "Save one set of keys and reuse it for as many syncs as you like."
            )

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Personal AWS"))
                } footer: {
                    Text("Only you see this name. It is how you will pick these keys when creating a sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    CredentialKeyFields(
                        accessKey: $accessKey,
                        secretKey: $secretKey,
                        sessionToken: $sessionToken,
                        keepPrompt: isEditing ? "Leave blank to keep the saved key" : nil
                    )
                } header: {
                    Text(isEditing ? "Replace Keys" : "Keys")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "Keys are stored only in your macOS Keychain.",
                            systemImage: "lock"
                        )
                        if isEditing {
                            Text("Leave all three blank to keep the keys you already saved. A replacement needs both the access key and the secret key — StorageSync never reads the saved secret back.")
                        }
                        if isReplacingKeys, dependents.count > 1 {
                            Label(
                                "\(dependents.count) syncs use these credentials and will switch to the new keys immediately.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        }
                        if isReplacingKeys, !dependents.isEmpty {
                            Text("The new keys are tried against \(dependents[0].name)’s bucket before anything is saved.")
                        } else if isReplacingKeys, !isEditing {
                            Text("These are not checked against a bucket yet — that happens when you attach them to a sync.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            Divider()

            footer
        }
        .frame(width: 560, height: isEditing ? 480 : 440)
        .alert("Couldn’t Save Credentials", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isSaving {
                Text(isReplacingKeys && !dependents.isEmpty ? "Checking the new keys…" : "Saving…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let missing = missingRequirement {
                Text(missing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(isEditing ? "Save" : "Add Credentials", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(missingRequirement != nil || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var missingRequirement: String? {
        if trimmedName.isEmpty { return "Give these credentials a name." }
        if model.credentials.contains(where: {
            $0.id != existing?.id && $0.name.lowercased() == trimmedName.lowercased()
        }) {
            return "Credentials named “\(trimmedName)” already exist."
        }
        if isReplacingKeys, accessKey.trimmed.isEmpty || secretKey.trimmed.isEmpty {
            return "Enter the access key and secret key."
        }
        return nil
    }

    private var keys: S3Credentials? {
        guard isReplacingKeys else { return nil }
        return S3Credentials(
            accessKeyID: accessKey.trimmed,
            secretAccessKey: secretKey.trimmed,
            sessionToken: sessionToken.nilIfBlank
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await model.saveCredential(id: existing?.id, name: trimmedName, keys: keys)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

/// The three key fields, identical everywhere they are asked for.
struct CredentialKeyFields: View {
    @Binding var accessKey: String
    @Binding var secretKey: String
    @Binding var sessionToken: String
    /// Shown in place of the usual prompts where blank means "keep the saved
    /// key" rather than "not filled in yet".
    var keepPrompt: String?

    var body: some View {
        TextField("Access key", text: $accessKey, prompt: keepPrompt.map(Text.init))
        SecureField("Secret key", text: $secretKey, prompt: keepPrompt.map(Text.init))
        SecureField(
            "Session token",
            text: $sessionToken,
            prompt: Text(keepPrompt ?? "Optional")
        )
    }
}
