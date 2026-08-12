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
    @State private var expandedJobIDs: Set<SyncJobID> = []

    var body: some View {
        List(selection: $model.selection) {
            Section("Syncs") {
                ForEach(model.jobs) { job in
                    SyncSidebarDisclosure(
                        job: job,
                        status: model.status(for: job),
                        snapshot: model.snapshot(for: job.id),
                        connection: model.connection(for: job),
                        credential: model.credential(for: job),
                        isExpanded: expandedJobIDs.contains(job.id),
                        isSelected: model.selection == .sync(job.id),
                        toggleExpanded: {
                            withAnimation(.snappy(duration: 0.2)) {
                                if expandedJobIDs.contains(job.id) {
                                    expandedJobIDs.remove(job.id)
                                } else {
                                    expandedJobIDs.insert(job.id)
                                }
                            }
                        },
                        select: { model.selection = .sync(job.id) }
                    )
                        .listRowBackground(
                            model.selection == .sync(job.id)
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                        .contextMenu {
                            Button(model.isCheckingForChanges(job.id) ? "Checking for Changes…" : "Sync Now") {
                                Task { await model.syncNow(job) }
                            }
                            .disabled(!model.canSyncNow(job))
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
        .navigationSplitViewColumnWidth(min: 230, ideal: 276, max: 360)
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

private struct SyncSidebarDisclosure: View {
    let job: SyncJob
    let status: SyncStatus
    let snapshot: SyncSnapshot
    let connection: S3Connection?
    let credential: StoredCredential?
    let isExpanded: Bool
    let isSelected: Bool
    let toggleExpanded: () -> Void
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide sync details" : "Show sync details")
                .accessibilityLabel(isExpanded ? "Collapse \(job.name) details" : "Expand \(job.name) details")

                Button(action: select) {
                    HStack(spacing: 6) {
                        Label(job.name, systemImage: SyncRoute.symbol(job))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: status.symbol)
                            .imageScale(.small)
                            .foregroundStyle(status.tint)
                            .accessibilityLabel(status.title)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows this sync’s status and transfers")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    SidebarDetailLine(
                        symbol: job.direction == .upload ? "arrow.up" : "arrow.down",
                        title: job.direction == .upload ? "This Mac → S3" : "S3 → This Mac"
                    )
                    SidebarDetailLine(symbol: "folder", title: job.localRoot.displayName)
                    SidebarDetailLine(
                        symbol: "shippingbox",
                        title: bucketDescription
                    )
                    if let credential {
                        SidebarDetailLine(symbol: "key", title: credential.name)
                    }
                    SidebarDetailLine(
                        symbol: "clock",
                        title: snapshot.lastSuccessfulSync.map {
                            "Last checked \($0.formatted(date: .abbreviated, time: .shortened))"
                        } ?? "Not checked yet"
                    )
                    Label("Destination files are never removed", systemImage: "checkmark.shield")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 28)
                .padding(.top, 6)
                .padding(.bottom, 5)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .help(status.title)
    }

    private var bucketDescription: String {
        guard let connection else { return "Bucket unavailable" }
        return job.remotePrefix.isEmpty
            ? connection.bucket
            : "\(connection.bucket)/\(job.remotePrefix)"
    }
}

private struct SidebarDetailLine: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(title)
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
        VStack(spacing: 0) {
            ScrollView {
                StatusHeader(job: job, snapshot: snapshot, status: status, model: model)
                    .padding(18)
            }
            .frame(maxHeight: 310)
            .background(.background.secondary)

            Divider()

            TransferActivityView(job: job, model: model)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                if model.isCheckingForChanges(job.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Checking for changes")
                } else {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
            }
            .help(model.isCheckingForChanges(job.id) ? "Checking for changes…" : "Check for new and changed files now")
            .disabled(!model.canSyncNow(job))
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

                if model.transferActivityCounts.all > 0 {
                    ActivityCountSummary(counts: model.transferActivityCounts)
                        .padding(.top, 3)
                }

                if let count = snapshot.recentlyQueuedCount, count > 0,
                   let paths = snapshot.recentlyQueuedPaths,
                   let queuedAt = snapshot.recentlyQueuedAt {
                    RecentlyQueuedView(count: count, paths: paths, queuedAt: queuedAt)
                        .padding(.top, 4)
                }

                if let notice = snapshot.sourceChangeNotice {
                    Label(notice, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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

private struct ActivityCountSummary: View {
    let counts: TransferActivityCounts

    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityLabel(parts.joined(separator: ", "))
    }

    private var parts: [String] {
        var values: [String] = []
        if counts.active > 0 { values.append("\(counts.active.formatted()) active") }
        if counts.waiting > 0 { values.append("\(counts.waiting.formatted()) waiting") }
        if counts.completed > 0 { values.append("\(counts.completed.formatted()) done") }
        if counts.issues > 0 { values.append("\(counts.issues.formatted()) issues") }
        return values
    }
}

/// A scan result the user can verify directly. Only a bounded path sample is
/// carried in the snapshot, so this remains small on an initial pairing with
/// millions of files.
private struct RecentlyQueuedView: View {
    let count: Int
    let paths: [String]
    let queuedAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Latest check queued \(count.formatted()) new or changed \(count == 1 ? "file" : "files")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if count > paths.count {
                    Text("and \((count - paths.count).formatted()) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("Detected \(queuedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
