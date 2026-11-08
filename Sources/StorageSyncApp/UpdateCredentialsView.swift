import StorageSyncCore
import SwiftUI

/// Chooses which saved credentials one sync uses — and, when the trouble is the
/// keys themselves rather than the choice, replaces them here rather than
/// sending the user to the Credentials list to find the same three fields.
///
/// Whatever route is taken, the keys are proved against this sync's own bucket
/// before it is switched over. Saved progress is untouched: an interrupted
/// transfer resumes from its checkpoint as soon as the keys work again.
struct UpdateCredentialsView: View {
    let job: SyncJob
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choice: CredentialChoice
    @State private var name = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var sessionToken = ""
    @State private var isTesting = false
    @State private var errorMessage: String?

    init(job: SyncJob, model: AppModel) {
        self.job = job
        _model = ObservedObject(wrappedValue: model)
        _choice = State(
            initialValue: model.credential(for: job).map { CredentialChoice.saved($0.id) } ?? .new
        )
    }

    private var isCreating: Bool { choice == .new }

    private var chosen: StoredCredential? {
        guard case .saved(let id) = choice else { return nil }
        return model.credentials.first { $0.id == id }
    }

    /// Any entry at all means the saved keys are being replaced.
    private var isReplacingKeys: Bool {
        isCreating || !accessKey.trimmed.isEmpty || !secretKey.trimmed.isEmpty || !sessionToken.trimmed.isEmpty
    }

    private var sharedWith: [SyncJob] {
        guard let chosen else { return [] }
        return model.syncsUsing(chosen).filter { $0.id != job.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Credentials",
                subtitle: "Which keys “\(job.name)” uses. Saved progress is kept and resumes as soon as they work."
            )

            Divider()

            Form {
                if !model.credentials.isEmpty {
                    Section {
                        Picker("Use", selection: $choice) {
                            ForEach(model.credentials) { credential in
                                Text(label(for: credential)).tag(CredentialChoice.saved(credential.id))
                            }
                            Divider()
                            Text("New Credentials…").tag(CredentialChoice.new)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } header: {
                        Text("Use")
                    } footer: {
                        if let chosen, chosen.id != model.credential(for: job)?.id {
                            Text("This sync switches to “\(chosen.name)”. StorageSync checks them against this bucket first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if isCreating {
                        TextField("Name", text: $name, prompt: Text(defaultName))
                    }
                    CredentialKeyFields(
                        accessKey: $accessKey,
                        secretKey: $secretKey,
                        sessionToken: $sessionToken,
                        keepPrompt: isCreating ? nil : "Leave blank to keep the saved key"
                    )
                } header: {
                    Text(isCreating ? "New Keys" : "Replace Keys")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "Keys are tested before they replace the saved copy in your Keychain.",
                            systemImage: "lock"
                        )
                        if !isCreating {
                            Text("Leave these blank to keep using the saved keys unchanged.")
                        }
                        let routeUsers = model.jobs.filter { $0.id != job.id && $0.connectionID == job.connectionID }
                        if !routeUsers.isEmpty {
                            Text("This saved bucket connection is also used by \(routeUsers.map(\.name).formatted(.list(type: .and))). Changing its credentials updates those syncs too.")
                        }
                        if isReplacingKeys, !sharedWith.isEmpty {
                            Label(
                                sharedWith.count == 1
                                    ? "“\(sharedWith[0].name)” uses these credentials too and will switch to the new keys."
                                    : "\(sharedWith.count) other syncs use these credentials and will switch to the new keys.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isTesting)

            Divider()

            footer
        }
        .frame(width: 560, height: 460)
        .alert("Couldn’t Update Credentials", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isTesting {
                Text("Testing against \(job.name)’s bucket…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let missing = missingRequirement {
                Text(missing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if isTesting { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isTesting)
            Button("Update", action: update)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(missingRequirement != nil || isTesting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var defaultName: String {
        model.connection(for: job)?.name ?? "Amazon S3"
    }

    private var trimmedName: String {
        let typed = StoredCredential.normalizedName(name)
        return typed.isEmpty ? defaultName : typed
    }

    private var missingRequirement: String? {
        if isCreating {
            if model.credentials.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
                return "Credentials named “\(trimmedName)” already exist. Choose another name."
            }
            if accessKey.trimmed.isEmpty || secretKey.trimmed.isEmpty {
                return "Enter the access key and secret key."
            }
            return nil
        }
        if isReplacingKeys, accessKey.trimmed.isEmpty || secretKey.trimmed.isEmpty {
            return "Enter the access key and secret key, or clear both to keep the saved ones."
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

    private func label(for credential: StoredCredential) -> String {
        guard let summary = credential.accessKeySummary else { return credential.name }
        return "\(credential.name) — \(summary)"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func update() {
        isTesting = true
        Task {
            do {
                try await model.updateCredentials(
                    for: job,
                    choice: choice,
                    name: trimmedName,
                    keys: keys
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isTesting = false
            }
        }
    }
}
