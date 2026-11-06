import Foundation

/// One of the person's own Gmail labels.
nonisolated struct GmailLabel: Identifiable, Equatable, Sendable {
    /// Gmail's "Show in label list" setting.
    enum Visibility: String, Sendable {
        case show = "labelShow"
        case showIfUnread = "labelShowIfUnread"
        case hide = "labelHide"
    }

    let id: String
    /// The whole path, as nesting is only a naming convention: "Work/Clients".
    let name: String
    var visibility: Visibility = .show
    var unreadThreads = 0

    /// A name with an empty part, such as "/Work", is not nested: it is taken as written.
    fileprivate var pathComponents: [String] {
        let parts = name.components(separatedBy: "/")
        return parts.contains(where: \.isEmpty) ? [name] : parts
    }

    /// The last part of the path: "Clients".
    var shortName: String { pathComponents.last ?? name }

    /// Whether it shows in the list itself rather than under More.
    fileprivate var isListed: Bool {
        switch visibility {
        case .show: true
        case .showIfUnread: unreadThreads > 0
        case .hide: false
        }
    }
}

/// A row of the Labels section. A parent that only exists as part of its children's names has no label.
nonisolated struct LabelNode: Identifiable, Equatable, Sendable {
    let path: String
    let title: String
    let label: GmailLabel?
    let children: [LabelNode]

    var id: String { path }
    var unreadThreads: Int { label?.unreadThreads ?? 0 }
    /// What a collapsed row stands for: its own unread threads and those of everything inside it.
    var unreadThreadsIncludingChildren: Int {
        children.reduce(unreadThreads) { $0 + $1.unreadThreadsIncludingChildren }
    }
}

/// An account's labels as the sidebar shows them.
nonisolated struct LabelTree: Equatable, Sendable {
    /// The labels Gmail lists, nested by name.
    let roots: [LabelNode]
    /// The rest, by their whole name: a parent of theirs may be up in `roots`, which a row can't also be part of here.
    let more: [LabelNode]

    var isEmpty: Bool { roots.isEmpty && more.isEmpty }

    init(_ labels: [GmailLabel] = []) {
        let labelsByPath = Dictionary(labels.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // Every listed label brings its parents along, whether or not those are listed or even labels.
        var childPaths: [String: Set<String>] = [:]
        var titles: [String: String] = [:]
        var placed: Set<String> = []
        for label in labels where label.isListed {
            var parent = ""
            for component in label.pathComponents {
                let path = parent.isEmpty ? component : parent + "/" + component
                childPaths[parent, default: []].insert(path)
                titles[path] = component
                placed.insert(path)
                parent = path
            }
        }
        func nodes(under parent: String) -> [LabelNode] {
            (childPaths[parent] ?? []).map { path in
                LabelNode(path: path, title: titles[path] ?? path, label: labelsByPath[path], children: nodes(under: path))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        roots = nodes(under: "")
        more = labels.filter { !placed.contains($0.name) }
            .map { LabelNode(path: $0.name, title: $0.name, label: $0, children: []) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
