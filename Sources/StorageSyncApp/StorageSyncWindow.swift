import StorageSyncCore
import SwiftUI

struct StorageSyncWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SyncSidebar(model: model)
        } detail: {
            if let job = model.selectedJob {
                SyncDetail(
                    job: job,
                    snapshot: model.snapshot(for: job.id),
                    connection: model.connection(for: job),
                    model: model
                )
                // Rebuild the detail pane when the selection changes so the
                // scroll position does not carry over between syncs.
                .id(job.id)
            } else if let credential = model.selectedCredential {
                CredentialDetailView(credential: credential, model: model)
                    .id(credential.id)
            } else {
                WelcomeView(
                    hasSyncs: !model.jobs.isEmpty,
                    isAgentAvailable: model.isAgentAvailable
                ) { model.beginCreatingSync() }
            }
        }
        .sheet(isPresented: $model.isCreatingSync) {
            CreateSyncView(model: model)
        }
        .sheet(item: $model.credentialsJob) { job in
            UpdateCredentialsView(job: job, model: model)
        }
        .sheet(item: $model.credentialEditor) { request in
            CredentialEditorView(request: request, model: model)
        }
        .alert(
            "Delete These Credentials?",
            isPresented: credentialRemovalBinding,
            presenting: model.credentialPendingRemoval
        ) { credential in
            Button("Delete Credentials", role: .destructive) {
                Task { await model.confirmRemoval(of: credential) }
            }
            Button("Cancel", role: .cancel) { model.cancelCredentialRemoval() }
        } message: { credential in
            Text("StorageSync forgets “\(credential.name)” and removes its keys from your Keychain. Nothing in your bucket changes, and the keys keep working everywhere else you use them.")
        }
        // The title stays constant while the alert dismisses; the name lives in
        // the message, which is driven by the presented value.
        .alert("Remove This Sync?", isPresented: removalBinding, presenting: model.jobPendingRemoval) { job in
            Button("Remove Sync", role: .destructive) {
                Task { await model.confirmRemoval(of: job) }
            }
            Button("Cancel", role: .cancel) { model.cancelRemoval() }
        } message: { job in
            Text("StorageSync forgets “\(job.name)” and its resumable progress. Files on this Mac, on external drives, and in S3 all stay exactly where they are.")
        }
        .alert("StorageSync", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { model.jobPendingRemoval != nil },
            set: { if !$0 { model.cancelRemoval() } }
        )
    }

    private var credentialRemovalBinding: Binding<Bool> {
        Binding(
            get: { model.credentialPendingRemoval != nil },
            set: { if !$0 { model.cancelCredentialRemoval() } }
        )
    }
}

// MARK: - Sidebar

private struct SyncSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Syncs") {
                ForEach(model.jobs) { job in
                    SidebarRow(job: job, status: model.status(for: job))
                        .tag(ManagerSelection.sync(job.id))
                        .contextMenu {
                            Button("Sync Now") { Task { await model.syncNow(job) } }
                            if job.isPaused {
                                Button("Resume") { Task { await model.resume(job) } }
                            } else {
                                Button("Pause") { Task { await model.pause(job) } }
                            }
                            Divider()
                            Button("Show in Finder") { model.revealInFinder(job) }
                            Divider()
                            Button("Remove Sync…", role: .destructive) { model.requestRemoval(of: job) }
                        }
                }
            }

            // Hidden until there is one. The first set is saved while creating
            // a sync, so an empty section would only ever be an empty section.
            if !model.credentials.isEmpty {
                Section("Credentials") {
                    ForEach(model.credentials) { credential in
                        CredentialSidebarRow(
                            credential: credential,
                            usedByCount: model.syncsUsing(credential).count
                        )
                        .tag(ManagerSelection.credential(credential.id))
                        .contextMenu {
                            Button("Edit Credentials…") { model.beginEditingCredential(credential) }
                            Button("Create Sync with These…") { model.beginCreatingSync(using: credential) }
                            Divider()
                            Button("Delete Credentials…", role: .destructive) {
                                model.requestRemoval(of: credential)
                            }
                            .disabled(!model.syncsUsing(credential).isEmpty)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AgentStatusBar(
                isAvailable: model.isAgentAvailable,
                needsApproval: model.needsLoginItemsApproval,
                openLoginItems: { model.openLoginItemsSettings() }
            )
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Sync…") { model.beginCreatingSync() }
                    Button("New Credentials…") { model.beginCreatingCredential() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("Create a sync, or save credentials to reuse")
            }
        }
    }
}

/// Saved keys read as one line: what they are called, and the shortened access
/// key that tells two sets from the same provider apart.
private struct CredentialSidebarRow: View {
    let credential: StoredCredential
    let usedByCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(credential.name)
                        .lineLimit(1)
                    if let summary = credential.accessKeySummary {
                        Text(summary)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: credential.hasSessionToken ? "key.slash" : "key")
            }
            Spacer(minLength: 4)
            if usedByCount > 0 {
                Text("\(usedByCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(usedByCount) syncs")
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        switch usedByCount {
        case 0: "Not used by any sync yet"
        case 1: "Used by one sync"
        default: "Used by \(usedByCount) syncs"
        }
    }
}

private struct SidebarRow: View {
    let job: SyncJob
    let status: SyncStatus

    var body: some View {
        HStack(spacing: 6) {
            Label(job.name, systemImage: SyncRoute.symbol(job))
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: status.symbol)
                .imageScale(.small)
                .foregroundStyle(status.tint)
                .accessibilityLabel(status.title)
        }
        .help(status.title)
    }
}

/// The engine lives in a separate login agent, so whether it is reachable is a
/// fact the window should state rather than hide behind a stalled progress bar.
private struct AgentStatusBar: View {
    let isAvailable: Bool
    let needsApproval: Bool
    let openLoginItems: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: isAvailable ? "bolt.horizontal.circle.fill" : "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(isAvailable ? Color.green : Color.orange)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Only macOS can grant this, so the one useful thing to offer is
                // the settings pane that grants it.
                if needsApproval && !isAvailable {
                    Button("Allow…", action: openLoginItems)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .help(helpText)
    }

    private var title: String {
        if isAvailable { return "Syncing in the background" }
        return needsApproval ? "Waiting for approval in Login Items" : "Starting background syncing…"
    }

    private var helpText: String {
        if isAvailable { return "Transfers keep running after this window is closed." }
        if needsApproval {
            return "Turn StorageSync on in System Settings › General › Login Items & Extensions so syncing can run in the background."
        }
        return "StorageSync is starting its background agent. Transfers begin as soon as it is running."
    }
}

// MARK: - Empty state

private struct WelcomeView: View {
    let hasSyncs: Bool
    let isAgentAvailable: Bool
    let create: () -> Void

    /// An empty sidebar means "no syncs exist" only after the agent has
    /// answered. Until then the syncs are merely unread, not absent, and
    /// inviting the user to create one would be wrong.
    private var isWaitingForAgent: Bool { !hasSyncs && !isAgentAvailable }

    var body: some View {
        ContentUnavailableView {
            Label(
                isWaitingForAgent ? "Connecting…" : "Keep a Folder Safely Copied",
                systemImage: isWaitingForAgent ? "bolt.horizontal.circle" : "arrow.triangle.2.circlepath"
            )
        } description: {
            Text(description)
        } actions: {
            if !hasSyncs && !isWaitingForAgent {
                Button("Create Sync…", action: create)
                    .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("StorageSync")
    }

    private var description: String {
        if isWaitingForAgent {
            return "Reconnecting to the background agent. Your syncs are safe and keep running."
        }
        if hasSyncs {
            return "Choose a sync in the sidebar to see what it is doing."
        }
        return "Pair a folder with an S3 bucket. StorageSync copies new and changed files one way and never removes anything at the destination."
    }
}

// MARK: - Detail

private struct SyncDetail: View {
    let job: SyncJob
    let snapshot: SyncSnapshot
    let connection: S3Connection?
    @ObservedObject var model: AppModel

    private var status: SyncStatus { SyncStatus(job: job, snapshot: snapshot) }

    var body: some View {
        Form {
            Section {
                StatusHeader(job: job, snapshot: snapshot, status: status, model: model)
            }

            Section {
                LabeledContent("Copies") {
                    Text(job.direction == .upload ? "This Mac → S3" : "S3 → This Mac")
                }
                LabeledContent("Folder") {
                    HStack(spacing: 6) {
                        Text(job.localRoot.fallbackPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            model.revealInFinder(job)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                    }
                }
                LabeledContent("Bucket", value: connection?.bucket ?? "—")
                LabeledContent("Region", value: connection?.region ?? "—")
                LabeledContent(
                    "Folder in Bucket",
                    value: job.remotePrefix.isEmpty ? "Top level" : job.remotePrefix
                )
                LabeledContent("Credentials") {
                    if let credential = model.credential(for: job) {
                        Button {
                            model.selection = .credential(credential.id)
                        } label: {
                            HStack(spacing: 4) {
                                Text(credential.name)
                                Image(systemName: "chevron.forward")
                                    .imageScale(.small)
                            }
                        }
                        .buttonStyle(.link)
                        .help("Show these credentials")
                    } else {
                        Text("—")
                    }
                }
                if let last = snapshot.lastSuccessfulSync {
                    LabeledContent(
                        "Last Checked",
                        value: last.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            } header: {
                Text("Details")
            } footer: {
                Label(
                    "Destination files are never removed. Deleting or renaming a source file leaves its existing copy untouched.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(job.name)
        .navigationSubtitle(SyncRoute.text(job, connection: connection))
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task {
                    if job.isPaused { await model.resume(job) } else { await model.pause(job) }
                }
            } label: {
                Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play.fill" : "pause.fill")
            }
            .help(job.isPaused ? "Resume this sync" : "Pause this sync")

            Button {
                Task { await model.syncNow(job) }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .help("Check for new and changed files now")
            .disabled(job.isPaused)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Change Credentials…") { model.credentialsJob = job }
                Button("Show in Finder") { model.revealInFinder(job) }
                Divider()
                Button("Remove Sync…", role: .destructive) { model.requestRemoval(of: job) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More actions")
        }
    }
}

private struct StatusHeader: View {
    let job: SyncJob
    let snapshot: SyncSnapshot
    let status: SyncStatus
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.symbol)
                .font(.system(size: 26))
                .foregroundStyle(status.tint)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(status.title)
                    .font(.headline)
                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reading = model.balanceReading(for: job) {
                    StorageBalanceView(
                        reading: reading,
                        isTransferring: snapshot.phase == .transferring
                    )
                    .padding(.top, 8)
                }

                if let current = snapshot.currentRelativePath {
                    Text(current)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }

                if snapshot.blockers.contains(.credentialsUnavailable) {
                    Button("Fix Credentials…") { model.credentialsJob = job }
                        .padding(.top, 6)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
