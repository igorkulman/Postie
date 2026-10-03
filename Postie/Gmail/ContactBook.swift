import Foundation

/// Someone the person could address a message to, learned from mail already in the account.
nonisolated struct ContactSuggestion: Identifiable, Equatable, Hashable, Sendable {
    let name: String
    let email: String

    var id: String { email.lowercased() }
}

/// The address headers of one cached message, which is all contact suggestions are built from.
nonisolated struct ContactSource: Equatable, Sendable {
    let senderName: String
    let senderEmail: String
    let recipient: String
    let cc: String
    let date: Date
}

/// A person from the account's Google contacts. `isSaved` tells the contacts the person saved from the ones
/// Google collected by itself from the people they have written to.
nonisolated struct DirectoryContact: Equatable, Hashable, Sendable {
    let name: String
    let email: String
    let isSaved: Bool
}

nonisolated protocol GmailContactLoading: Sendable {
    func contacts() async throws -> [DirectoryContact]
}

nonisolated enum ContactBook {
    /// Splits an address header like `"Doe, Jo" <jo@x.com>, bob@y.com` into names and addresses.
    static func parse(_ header: String) -> [(name: String, email: String)] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var inBrackets = false
        for character in header {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "<" where !inQuotes: inBrackets = true; current.append(character)
            case ">" where !inQuotes: inBrackets = false; current.append(character)
            case "," where !inQuotes && !inBrackets: entries.append(current); current = ""
            default: current.append(character)
            }
        }
        entries.append(current)
        return entries.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let email = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                let name = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: .whitespaces)
                return isAddress(email) ? (name, email) : nil
            }
            return isAddress(trimmed) ? ("", trimmed) : nil
        }
    }

    private static func isAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !value.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," })
    }

    /// People matching `query`, best first: those you write to beat those who write to you, and
    /// frequent and recent beat rare and old. `ownEmail` is never suggested.
    static func suggestions(from sources: [ContactSource], directory: [DirectoryContact] = [], matching query: String,
                            excluding ownEmail: String, limit: Int = 8) -> [ContactSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let own = ownEmail.lowercased()

        struct Entry { var name: String; var email: String; var score = 0; var latest = Date.distantPast; var nameDate = Date.distantPast }
        var entries: [String: Entry] = [:]

        func record(name: String, email: String, weight: Int, date: Date, nameDate: Date? = nil) {
            let key = email.lowercased()
            guard key != own else { return }
            var entry = entries[key] ?? Entry(name: "", email: email)
            entry.score += weight
            entry.latest = max(entry.latest, date)
            // Prefer the most recent real display name over a bare address.
            let namedAt = nameDate ?? date
            if !name.isEmpty, namedAt >= entry.nameDate { entry.name = name; entry.nameDate = namedAt }
            entries[key] = entry
        }

        // Contacts the person saved are the best answer, and the name they gave beats any header's.
        for contact in directory {
            record(name: contact.name, email: contact.email, weight: contact.isSaved ? 6 : 2, date: .distantPast,
                   nameDate: contact.isSaved ? .distantFuture : .distantPast.addingTimeInterval(1))
        }

        for source in sources {
            if source.senderEmail.lowercased() == own {
                // Mail you sent: everyone you addressed counts for more.
                for person in parse(source.recipient) + parse(source.cc) { record(name: person.name, email: person.email, weight: 3, date: source.date) }
            } else {
                record(name: source.senderName, email: source.senderEmail, weight: 1, date: source.date)
                for person in parse(source.recipient) + parse(source.cc) { record(name: person.name, email: person.email, weight: 1, date: source.date) }
            }
        }

        func rank(_ entry: Entry) -> Int? {
            let email = entry.email.lowercased(), name = entry.name.lowercased()
            if email.hasPrefix(needle) || name.hasPrefix(needle) { return 0 }
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) { return 0 }
            if email.contains(needle) || name.contains(needle) { return 1 }
            return nil
        }

        return entries.values
            .compactMap { entry in rank(entry).map { (entry, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.score != rhs.0.score { return lhs.0.score > rhs.0.score }
                if lhs.0.latest != rhs.0.latest { return lhs.0.latest > rhs.0.latest }
                return lhs.0.email.lowercased() < rhs.0.email.lowercased()
            }
            .prefix(limit)
            .map { ContactSuggestion(name: $0.0.name, email: $0.0.email) }
    }
}
