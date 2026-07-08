import Foundation

public struct Note: Identifiable, Equatable, Sendable {
    public let id: String
    public var url: URL
    public var content: String
    public var modifiedDate: Date

    public init(id: String, url: URL, content: String, modifiedDate: Date) {
        self.id = id
        self.url = url
        self.content = content
        self.modifiedDate = modifiedDate
    }

    public var title: String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Untitled" : name
    }

    public var preview: String {
        content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
