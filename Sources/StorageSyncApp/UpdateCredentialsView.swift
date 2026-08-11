import StorageSyncCore
import SwiftUI

struct UpdateCredentialsView: View {
    let job: SyncJob
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var sessionToken = ""
    @State private var isTesting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Update S3 Credentials",
                subtitle: "New keys for “\(job.name)”. Saved progress is kept and resumes as soon as they work."
            )

            Divider()

            Form {
                Section {
                    TextField("Access key", text: $accessKey)
                    SecureField("Secret key", text: $secretKey)
                    SecureField("Session token", text: $sessionToken, prompt: Text("Optional"))
                } footer: {
                    Label(
                        "StorageSync tests these keys before replacing the saved copy in your Keychain.",
                        systemImage: "lock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isTesting)

            Divider()

            HStack(spacing: 12) {
                if isTesting {
                    Text("Testing the new keys…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if isTesting { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isTesting)
                Button("Update", action: update)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete || isTesting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 340)
        .alert("Couldn’t Update Credentials", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var isComplete: Bool {
        !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !secretKey.isEmpty
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
                    accessKey: accessKey,
                    secretKey: secretKey,
                    sessionToken: sessionToken
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isTesting = false
            }
        }
    }
}
