import Foundation

/// Short display names are presentation only; expanded headers always keep the original addresses.
nonisolated enum RecipientSummary {
    static func names(in header: String, accountEmail: String?) -> String {
        let people = ContactBook.parse(header)
        guard !people.isEmpty else { return header.trimmingCharacters(in: .whitespacesAndNewlines) }
        return people.map { person in
            if let accountEmail, person.email.caseInsensitiveCompare(accountEmail) == .orderedSame {
                return String(localized: "me")
            }
            return person.name.isEmpty ? person.email : person.name
        }.joined(separator: ", ")
    }

    static func text(to: String, cc: String, accountEmail: String?) -> String {
        var parts: [String] = []
        if !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(String(localized: "To: \(names(in: to, accountEmail: accountEmail))"))
        }
        if !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(String(localized: "Cc: \(names(in: cc, accountEmail: accountEmail))"))
        }
        return parts.isEmpty ? String(localized: "Recipients not specified") : parts.joined(separator: " · ")
    }
}
