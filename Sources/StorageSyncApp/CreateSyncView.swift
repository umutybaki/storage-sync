import StorageSyncCore
import SwiftUI

struct CreateSyncView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: LocationID?
    @State private var destinationID: LocationID?
    @State private var name = ""
    @State private var isSaving = false
    @State private var isAddingLocation = false
    @State private var addingSource = true
    @State private var errorMessage: String?

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        let preferred = model.locations.first { $0.id == model.newSyncLocation }
        _sourceID = State(initialValue: preferred?.id)
    }

    private var source: StorageLocation? { model.locations.first { $0.id == sourceID } }
    private var destination: StorageLocation? { model.locations.first { $0.id == destinationID } }
    private var eligibleDestinations: [StorageLocation] {
        guard let source else { return model.locations }
        return model.locations.filter { ($0.localRoot != nil) != (source.localRoot != nil) }
    }
    private var requirement: String? {
        if !model.areLocationsAvailable { return "Waiting for the updated background agent…" }
        guard let source, let destination else { return "Choose a source and destination location." }
        do { _ = try SyncJob(name: "", source: source, destination: destination) }
        catch { return error.localizedDescription }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Create Sync", subtitle: "Choose where to copy from and where to copy to.")
            Divider()
            Form {
                Section {
                    locationPicker("From", selection: $sourceID, choices: model.locations, isSource: true)
                    if let source { locationPath(source) }
                    locationPicker("To", selection: $destinationID, choices: eligibleDestinations, isSource: false)
                    if let destination { locationPath(destination) }
                    if source != nil && destination != nil {
                        Button("Swap Locations", systemImage: "arrow.up.arrow.down") {
                            let previous = sourceID
                            sourceID = destinationID
                            destinationID = previous
                        }
                    }
                } header: { Text("Locations") } footer: {
                    Text("Choose one Mac folder and one cloud bucket. Saved locations can be reused by other syncs.")
                }
                Section {
                    LabeledContent("Behavior", value: "Copy changes")
                    TextField("Name", text: $name, prompt: Text(source?.localRoot != nil ? source?.name ?? "Optional" : destination?.name ?? "Optional"))
                } footer: {
                    Text("New and changed files are copied in one direction. Deleting a source file never deletes the destination copy.")
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)
            Divider()
            HStack(spacing: 12) {
                Text(isSaving ? "Creating sync…" : requirement ?? "\(source?.name ?? "") → \(destination?.name ?? "")")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Start Sync", action: start)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(requirement != nil || isSaving)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 580, height: 600)
        .onChange(of: sourceID) { _, _ in
            if let destinationID, !eligibleDestinations.contains(where: { $0.id == destinationID }) { self.destinationID = nil }
        }
        .sheet(isPresented: $isAddingLocation) {
            LocationEditorView(model: model, kind: addingSource ? .local : (source?.localRoot != nil ? .cloud : .local)) { location in
                if addingSource { sourceID = location.id }
                else { destinationID = location.id }
            }
        }
        .alert("Couldn’t Create Sync", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func locationPicker(_ title: String, selection: Binding<LocationID?>, choices: [StorageLocation], isSource: Bool) -> some View {
        HStack {
            Picker(title, selection: selection) {
                Text("Choose a location…").tag(nil as LocationID?)
                ForEach(choices) { location in
                    Text(location.name).tag(Optional(location.id))
                }
            }
            Button("New…") {
                addingSource = isSource
                isAddingLocation = true
            }
            .help("Save a new location")
            .disabled(!model.areLocationsAvailable)
        }
    }

    private func locationPath(_ location: StorageLocation) -> some View {
        Text(model.locationSummary(location)).font(.caption).foregroundStyle(.secondary)
            .lineLimit(2).textSelection(.enabled)
    }

    private func start() {
        guard let sourceID, let destinationID else { return }
        isSaving = true
        Task {
            do { try await model.createSync(name: name, sourceID: sourceID, destinationID: destinationID) }
            catch { errorMessage = error.localizedDescription; isSaving = false }
        }
    }
}
