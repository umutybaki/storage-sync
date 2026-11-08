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
            } else if let location = model.selectedLocation {
                LocationDetailView(location: location, model: model).id(location.id)
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
        .toolbar(removing: .sidebarToggle)
        .sheet(isPresented: $model.isCreatingSync) {
            CreateSyncView(model: model)
        }
        .sheet(isPresented: $model.isCreatingLocation) {
            LocationEditorView(model: model) { location in model.selection = .location(location.id) }
        }
        .sheet(item: $model.credentialsJob) { job in
            UpdateCredentialsView(job: job, model: model)
        }
        .sheet(item: $model.credentialEditor) { request in
            CredentialEditorView(request: request, model: model)
        }
        .alert("Remove This Location?", isPresented: Binding(
            get: { model.locationPendingRemoval != nil },
            set: { if !$0 { model.locationPendingRemoval = nil } }
        ), presenting: model.locationPendingRemoval) { location in
            Button("Remove Location", role: .destructive) { Task { await model.removeLocation(location) } }
            Button("Cancel", role: .cancel) { model.locationPendingRemoval = nil }
        } message: { location in
            Text("StorageSync forgets “\(location.name)”. Files and saved credentials stay where they are.")
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
    @AppStorage("sidebar.syncsExpanded") private var syncsExpanded = true
    @AppStorage("sidebar.locationsExpanded") private var locationsExpanded = true
    @AppStorage("sidebar.credentialsExpanded") private var credentialsExpanded = true

    var body: some View {
        List(selection: $model.selection) {
            Section("Syncs", isExpanded: $syncsExpanded) {
                ForEach(model.jobs) { job in
                    SyncSidebarRow(
                        job: job,
                        status: model.status(for: job),
                        snapshot: model.snapshot(for: job.id),
                        connection: model.connection(for: job),
                        credential: model.credential(for: job)
                    )
                        .tag(ManagerSelection.sync(job.id))
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
                            Button("Choose Folder…") { model.chooseFolderAgain(for: job) }
                            Divider()
                            Button("Remove Sync…", role: .destructive) { model.requestRemoval(of: job) }
                        }
                }
            }

            Section("Locations", isExpanded: $locationsExpanded) {
                ForEach(model.locations) { location in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.name).lineLimit(1)
                            Text(location.localRoot != nil ? "Mac Folder" : "Cloud Bucket")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: location.localRoot != nil ? "folder" : "externaldrive.badge.icloud") }
                    .tag(ManagerSelection.location(location.id))
                    .contextMenu {
                        Button("Create Sync with This Location…") { model.beginCreatingSync(location: location) }
                        Divider()
                        Button("Remove Location…", role: .destructive) { model.locationPendingRemoval = location }
                            .disabled(!model.syncsUsing(location).isEmpty)
                    }
                }
            }

            // Hidden until there is one. The first set is saved while creating
            // a sync, so an empty section would only ever be an empty section.
            if !model.credentials.isEmpty {
                Section("Credentials", isExpanded: $credentialsExpanded) {
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
                            .disabled(!model.syncsUsing(credential).isEmpty || !model.locationsUsing(credential).isEmpty)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
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
                    Button("New Location…") { model.isCreatingLocation = true }
                        .disabled(!model.areLocationsAvailable)
                    Button("New Credentials…") { model.beginCreatingCredential() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("New")
                .help("Create a sync, location, or saved credentials")
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

private struct SyncSidebarRow: View {
    let job: SyncJob
    let status: SyncStatus
    let snapshot: SyncSnapshot
    let connection: S3Connection?
    let credential: StoredCredential?
    @State private var showsInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .frame(width: 18)
                .accessibilityLabel(status.title)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .lineLimit(1)
                Text(SyncRoute.text(job, connection: connection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 2)

            Button {
                showsInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.medium)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show sync details")
            .accessibilityLabel("Show \(job.name) details")
            .popover(isPresented: $showsInfo, arrowEdge: .leading) {
                SyncInfoPopover(
                    job: job,
                    snapshot: snapshot,
                    connection: connection,
                    credential: credential
                )
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .help(status.title)
    }
}

private struct SyncInfoPopover: View {
    let job: SyncJob
    let snapshot: SyncSnapshot
    let connection: S3Connection?
    let credential: StoredCredential?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.headline)
                Text(SyncRoute.text(job, connection: connection))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                infoRow("Folder", value: job.localRoot.fallbackPath)
                infoRow("Bucket", value: connection?.bucket ?? "Unavailable")
                infoRow("Prefix", value: job.remotePrefix.isEmpty ? "Top level" : job.remotePrefix)
                infoRow("Region", value: connection?.region ?? "Unavailable")
                infoRow("Credentials", value: credential?.name ?? "Unavailable")
                infoRow("Last checked", value: lastChecked)
            }

            Divider()

            Label(
                "Destination files are never removed.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 360)
    }

    private var lastChecked: String {
        snapshot.lastSuccessfulSync?.formatted(date: .abbreviated, time: .shortened)
            ?? "Not checked yet"
    }

    private func infoRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                StatusHeader(job: job, snapshot: snapshot, status: status, model: model, barWidth: min(320, geometry.size.width * 0.32))
                    .padding(18)
                    .fixedSize(horizontal: false, vertical: true)

                TransferActivityView(job: job, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(.background)
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
                Button("Choose Folder…") { model.chooseFolderAgain(for: job) }
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
    let barWidth: CGFloat

    private var reading: BalanceReading? { model.balanceReading(for: job) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 24) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: status.symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(status.tint)
                        .frame(width: 30)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.title)
                            .font(.headline)
                        if let inventory {
                            Text("\(inventory.found.formatted()) files · \(inventory.present.formatted()) already present · \(inventory.remaining.formatted()) remaining")
                                .help(inventoryTooltip(inventory))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !status.detail.isEmpty, status.tone == .attention || status.tone == .waiting {
                            Text(status.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let reading {
                    StorageBalanceView(
                        reading: reading,
                        style: .barsOnly,
                        isTransferring: snapshot.phase == .transferring
                    )
                    .frame(width: barWidth)
                }
            }

            if model.transferActivityCounts.issues > 0 {
                Label("\(model.transferActivityCounts.issues.formatted()) files to review", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 44)
            }

            if let notice = snapshot.sourceChangeNotice {
                Label(notice, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }

            if snapshot.blockers.contains(.credentialsUnavailable) {
                Button("Fix Credentials…") { model.credentialsJob = job }
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private typealias Inventory = (found: Int, present: Int, remaining: Int, source: String, destination: String)

    private var inventory: Inventory? {
        // Location names follow the configured route, including download jobs
        // whose source is the cloud. Legacy jobs fall back to their endpoints.
        let localName = job.localRoot.displayName
        let remoteName = SyncRoute.remoteLabel(job, connection: model.connection(for: job))
        let sourceName = model.locations.first { $0.id == job.sourceLocationID }?.name
            ?? (job.direction == .upload ? localName : remoteName)
        let destinationName = model.locations.first { $0.id == job.destinationLocationID }?.name
            ?? (job.direction == .upload ? remoteName : localName)
        let sourceFiles: Int
        let alreadyPresent: Int
        let remaining: Int
        if let balance = reading?.balance {
            sourceFiles = job.direction == .upload ? balance.localFiles : balance.cloudFiles
            alreadyPresent = balance.sharedFiles
            remaining = balance.pendingFiles
        } else if let found = snapshot.sourceFilesFound, let present = snapshot.filesAlreadyPresent {
            sourceFiles = found
            alreadyPresent = present
            remaining = max(0, snapshot.filesTotal - snapshot.filesCompleted)
        } else {
            return nil
        }
        return (sourceFiles, alreadyPresent, remaining, sourceName, destinationName)
    }

    private func inventoryTooltip(_ inventory: Inventory) -> String {
        var lines = [
            "\(inventory.found.formatted()) files in \(inventory.source)",
            "\(inventory.present.formatted()) already in \(inventory.destination)",
            "\(inventory.remaining.formatted()) left to \(job.direction == .upload ? "upload" : "download")"
        ]
        let counts = model.transferActivityCounts
        if counts.all > 0 {
            lines.append("\(counts.active.formatted()) active · \(counts.waiting.formatted()) waiting · \(counts.completed.formatted()) done")
        }
        if let count = snapshot.recentlyQueuedCount, count > 0 {
            lines.append("Latest check queued \(count.formatted()) new or changed files")
            lines += snapshot.recentlyQueuedPaths ?? []
        }
        return lines.joined(separator: "\n")
    }
}
