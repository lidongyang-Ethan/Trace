import SwiftUI
import UniformTypeIdentifiers
import TraceCore

@MainActor
private final class PanelModel: ObservableObject {
    @Published var records: [RequestRecord] = []
    @Published var isPaused = false
    let store: DiagnosticsStore
    init(store: DiagnosticsStore) { self.store = store; refresh() }
    func refresh() {
        let snapshot = store.snapshot()
        if records != snapshot.records { records = snapshot.records }
        if isPaused != snapshot.isPaused { isPaused = snapshot.isPaused }
    }
    func observe() async {
        while !Task.isCancelled {
            refresh()
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }
}

/// Embed this view in a sheet or an existing navigation flow. It owns its NavigationStack.
@MainActor
public struct NetworkDiagnosticsView: View {
    @StateObject private var model: PanelModel
    @State private var query = ""
    @State private var filter: RequestFilter = .all
    @State private var showsSettings = false
    @State private var confirmsClear = false
    @State private var exportDocument: ExportDocument?
    @State private var showsExporter = false
    @State private var exportError: String?
    public init(store: DiagnosticsStore) { _model = StateObject(wrappedValue: PanelModel(store: store)) }

    private enum RequestFilter: String, CaseIterable { case all = "All", failures = "Failures", slow = "Slow" }
    private var filtered: [RequestRecord] {
        model.records.filter {
            (query.isEmpty || $0.url.localizedCaseInsensitiveContains(query)) &&
            (filter == .all || filter == .failures && $0.outcome.isFailure || filter == .slow && ($0.duration ?? 0) > 1)
        }
    }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(model.isPaused ? Color.secondary : .green).frame(width: 6, height: 6)
                    Text(model.isPaused ? TraceLocalization.text("Paused · New requests are not recorded") : TraceLocalization.text("Recording · Current session only"))
                    Spacer()
                    Text(TraceLocalization.format("%@ requests", String(describing: filtered.count)))
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 8)
                Picker(TraceLocalization.text("Filter requests"), selection: $filter) {
                    ForEach(RequestFilter.allCases, id: \.self) { Text(TraceLocalization.text($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "network").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.records.isEmpty ? TraceLocalization.text("No network requests") : TraceLocalization.text("No matching requests")).font(.headline)
                        Text(TraceLocalization.text("Only Alamofire sessions with a Trace monitor are recorded."))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                } else {
                    List(filtered) { record in
                        NavigationLink {
                            RequestDetailView(record: record, store: model.store)
                        } label: { RequestRow(record: record) }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle(TraceLocalization.text("Network requests"))
            .searchable(text: $query, prompt: TraceLocalization.text("Search path or host"))
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        model.store.setPaused(!model.isPaused); model.refresh()
                    } label: { Image(systemName: model.isPaused ? "play.fill" : "pause.fill") }
                        .accessibilityLabel(model.isPaused ? TraceLocalization.text("Resume recording") : TraceLocalization.text("Pause recording"))
                    Button {
                        model.refresh()
                        let records = filtered
                        guard !records.isEmpty else { return }
                        exportDocument = ExportDocument(records: records)
                        showsExporter = true
                    } label: {
                        Label(TraceLocalization.text("Export filtered requests"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(filtered.isEmpty)
                    Button { confirmsClear = true } label: { Image(systemName: "trash") }
                        .disabled(model.records.isEmpty)
                        .accessibilityLabel(TraceLocalization.text("Clear all records"))
                    Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(TraceLocalization.text("Recording settings"))
                }
            }
            .confirmationDialog(TraceLocalization.text("Clear all records from this session?"), isPresented: $confirmsClear, titleVisibility: .visible) {
                Button(TraceLocalization.text("Clear"), role: .destructive) {
                    model.store.clear(); model.refresh()
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView(store: model.store) }
        }
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "Trace-requests") { result in
            if case let .failure(error) = result, (error as NSError).code != NSUserCancelledError {
                exportError = error.localizedDescription
            }
        }
        .onChange(of: showsExporter) { presented in
            if !presented { exportDocument = nil }
        }
        .alert(TraceLocalization.text("Export failed"), isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button(TraceLocalization.text("Done")) { exportError = nil } }
        message: { Text(exportError ?? "") }
        .task { await model.observe() }
    }
}

private struct RequestRow: View {
    let record: RequestRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.method).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.blue)
                Text(record.path).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Text(record.outcome.isFailure ? record.outcome.title : record.statusCode.map(String.init) ?? record.outcome.title)
                    .font(.caption.weight(.medium)).foregroundStyle(record.outcome.isFailure ? .red : .secondary)
            }
            HStack {
                Text(record.startedAt, style: .time)
                Text(record.host).lineLimit(1)
                Spacer()
                Text(durationText(record)).monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}

@MainActor
private struct RequestDetailView: View {
    let recordID: UUID
    let store: DiagnosticsStore
    @State private var current: RequestRecord?

    init(record: RequestRecord, store: DiagnosticsStore) {
        recordID = record.id
        self.store = store
        _current = State(initialValue: store.record(id: record.id))
    }
    @State private var tab = 0
    @State private var showsReport = false
    var body: some View {
        Group {
            if let displayed = current {
                detail(displayed)
            } else {
                RemovedRecordView()
            }
        }
        .navigationTitle(current?.path ?? TraceLocalization.text("Request unavailable"))
        .sheet(isPresented: $showsReport) { ReportView(recordID: recordID, store: store) }
        .onAppear { tab = current?.outcome.isFailure == true ? 2 : 1 }
        .task {
            while !Task.isCancelled {
                current = store.record(id: recordID)
                if current == nil { showsReport = false }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
    private func detail(_ displayed: RequestRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(displayed.url).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    summary("HTTP", displayed.statusCode.map(String.init) ?? "—")
                    Spacer()
                    summary(TraceLocalization.text("Total duration"), durationText(displayed))
                    Spacer()
                    summary(TraceLocalization.text("Attempts"), String(displayed.attempts))
                }
                Text(displayed.outcome.title).font(.headline).foregroundStyle(displayed.outcome.isFailure ? .red : .primary)
                Picker(TraceLocalization.text("Detail category"), selection: $tab) {
                    Text(TraceLocalization.text("Request")).tag(0); Text(TraceLocalization.text("Response")).tag(1); Text(TraceLocalization.text("Diagnostics")).tag(2)
                }.pickerStyle(.segmented)
                if tab == 0 {
                    headers(displayed.requestHeaders)
                    bodyBlock(TraceLocalization.text("Request body"), displayed.requestBody)
                } else if tab == 1 {
                    headers(displayed.responseHeaders)
                    bodyBlock(TraceLocalization.text("Response body"), displayed.responseBody)
                } else {
                    timingSection(displayed.timing)
                    if let issue = displayed.issue {
                        Text(issue.summary).font(.headline)
                        if let path = issue.fieldPath { LabeledContent(TraceLocalization.text("Field path"), value: path) }
                        if let expected = issue.expectedType { LabeledContent(TraceLocalization.text("Expected type"), value: expected) }
                    } else {
                        Text(displayed.outcome == .running ? TraceLocalization.text("Waiting for the request to finish") : TraceLocalization.text("The client reported no processing errors. HTTP success does not imply business success."))
                    }
                    Text(TraceLocalization.text("Raw error descriptions are not saved. Custom serializers may not provide a field path."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { showsReport = true } label: {
                    Label(TraceLocalization.text("Preview redacted report"), systemImage: "doc.text")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent)
                Text(TraceLocalization.text("Only configured fields are redacted. Check free text for personal information before sharing."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
    private func timingSection(_ timing: NetworkTiming?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TraceLocalization.text("Network timing · last transaction")).font(.headline)
            if let timing {
                if timing.reusedConnection { Text(TraceLocalization.text("Reused connection")) }
                phase("DNS", timing.dns)
                phase("Connection (includes TLS)", timing.connection)
                phase("TLS", timing.tls)
                phase("Wait for first byte", timing.waitForFirstByte)
                phase("Response download", timing.download)
            } else {
                Text(TraceLocalization.text("Not provided")).foregroundStyle(.secondary)
            }
        }
    }

    private func phase(_ title: String, _ seconds: TimeInterval?) -> some View {
        LabeledContent(TraceLocalization.text(title), value: seconds.map {
            String(format: "%.0f ms", $0 * 1_000)
        } ?? TraceLocalization.text("Not provided"))
    }
    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
    private func headers(_ values: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TraceLocalization.text("Headers")).font(.headline)
            if values.isEmpty { Text(TraceLocalization.text("No headers")).foregroundStyle(.secondary) }
            ForEach(values.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                    Text(values[key] ?? "").font(.caption.monospaced()).textSelection(.enabled)
                }
                Divider()
            }
        }
    }
    private func bodyBlock(_ title: String, _ body: CapturedBody) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let count = body.originalByteCount { Text(TraceLocalization.format("Original body: %@ bytes", String(describing: count))).font(.caption).foregroundStyle(.secondary) }
            Text(body.displayText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
private struct SettingsView: View {
    let store: DiagnosticsStore
    @Environment(\.dismiss) private var dismiss
    @State private var capturesBodies = true
    @State private var maximumRecords = 200
    @State private var confirmsClear = false
    private var bodyBudgetDescription: String {
        let config = store.snapshot().configuration
        return TraceLocalization.format(
            "Up to %@ per body; %@ total. Non-JSON and oversized bodies are not saved.",
            ByteCountFormatter.string(fromByteCount: Int64(config.maximumBodyBytes), countStyle: .binary),
            ByteCountFormatter.string(fromByteCount: Int64(config.maximumTotalBodyBytes), countStyle: .binary)
        )
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(TraceLocalization.text("Capture")) {
                    Toggle(TraceLocalization.text("Capture JSON bodies"), isOn: $capturesBodies)
                    Picker(TraceLocalization.text("Record limit"), selection: $maximumRecords) {
                        ForEach(Array(Set([100, 200, 500, maximumRecords])).sorted(), id: \.self) { Text(TraceLocalization.format("%@ requests", String(describing: $0))).tag($0) }
                    }
                    Text(bodyBudgetDescription)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(TraceLocalization.text("Privacy")) {
                    LabeledContent(TraceLocalization.text("Authentication headers and cookies"), value: TraceLocalization.text("Always redacted"))
                    LabeledContent(TraceLocalization.text("Storage"), value: TraceLocalization.text("In memory only"))
                    Text(TraceLocalization.text("Changing capture settings clears existing records. The host configures sensitive fields; rules cannot cover all free text."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(TraceLocalization.text("Apply settings and clear records")) {
                        var config = store.snapshot().configuration
                        config.capturesBodies = capturesBodies; config.maximumRecords = maximumRecords
                        store.updateConfiguration(config); dismiss()
                    }
                    Button(TraceLocalization.text("Clear all records"), role: .destructive) { confirmsClear = true }
                }
            }
            .navigationTitle(TraceLocalization.text("Recording settings"))
            .toolbar { Button(TraceLocalization.text("Done")) { dismiss() } }
            .confirmationDialog(TraceLocalization.text("Clear all records from this session?"), isPresented: $confirmsClear, titleVisibility: .visible) {
                Button(TraceLocalization.text("Clear"), role: .destructive) { store.clear(); dismiss() }
            }
            .onAppear {
                let config = store.snapshot().configuration
                capturesBodies = config.capturesBodies; maximumRecords = config.maximumRecords
            }
        }
    }
}

@MainActor
private struct ReportView: View {
    let recordID: UUID
    let store: DiagnosticsStore
    @State private var report: String?

    init(recordID: UUID, store: DiagnosticsStore) {
        self.recordID = recordID
        self.store = store
        _report = State(initialValue: store.record(id: recordID).map { store.report(for: $0) })
    }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let report {
                    ScrollView {
                        Text(report).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                } else {
                    RemovedRecordView()
                }
            }
            .navigationTitle(TraceLocalization.text("Redacted report preview"))
            .toolbar {
                ToolbarItem { Button(TraceLocalization.text("Done")) { dismiss() } }
                ToolbarItem { if let report { ShareLink(item: report) { Label(TraceLocalization.text("Share report"), systemImage: "square.and.arrow.up") } } }
            }
        }
        .task {
            while !Task.isCancelled {
                report = store.record(id: recordID).map { store.report(for: $0) }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}

private struct RemovedRecordView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash").font(.largeTitle)
            Text(TraceLocalization.text("Request unavailable")).font(.headline)
            Text(TraceLocalization.text("This record was cleared or removed by the storage limit."))
                .font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private func durationText(_ record: RequestRecord) -> String {
    record.duration.map { String(format: "%.0f ms", $0 * 1_000) } ?? TraceLocalization.text("In progress")
}
