import SwiftUI
import UniformTypeIdentifiers
import TraceCore

struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    private let contents: Contents

    private enum Contents: Sendable {
        case export(RequestExport)
        case data(Data)
    }

    init(records: [RequestRecord]) {
        contents = .export(RequestExport(records: records))
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        contents = .data(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch contents {
        case .export(let export): return try FileWrapper(regularFileWithContents: export.jsonData())
        case .data(let data): return FileWrapper(regularFileWithContents: data)
        }
    }
}
