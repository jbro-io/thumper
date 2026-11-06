import Foundation

public struct ProcessPattern {
    public let text: String
    private let expression: NSRegularExpression?

    public init(_ text: String) throws {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        expression = self.text.isEmpty ? nil : try NSRegularExpression(pattern: self.text, options: .caseInsensitive)
    }

    public func matches(_ name: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    public func select(from processes: [ProcessRecord]) -> [TrackedProcess] {
        processes.filter { matches($0.name) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.pid < $1.id.pid : order == .orderedAscending
        }.map(TrackedProcess.init)
    }
}
