import SwiftUI

/// Looks up people for the address being typed. The query is the text and the account the message goes out from.
typealias ContactLookup = (String, String?) async -> [ContactSuggestion]

/// The part of a comma-separated address field that is still being typed.
nonisolated enum AddressToken {
    static func current(in text: String) -> String {
        let last = text.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` with the half-typed address replaced by `email`.
    static func completing(_ text: String, with email: String) -> String {
        guard let comma = text.lastIndex(of: ",") else { return email }
        return text[...comma] + " " + email
    }
}

private struct ContactSuggestionsModifier: ViewModifier {
    @Binding var text: String
    let isFocused: Bool
    let accountID: String?
    let lookup: ContactLookup

    @State private var suggestions: [ContactSuggestion] = []
    @State private var highlighted = 0

    private var token: String { AddressToken.current(in: text) }
    private var isShowing: Bool { isFocused && !suggestions.isEmpty }

    func body(content: Content) -> some View {
        content
            .task(id: token) { await refresh() }
            .onChange(of: isFocused) { if !isFocused { suggestions = [] } }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.return) { accept() }
            .onKeyPress(.tab) { accept() }
            .onKeyPress(.escape) {
                guard isShowing else { return .ignored }
                suggestions = []
                return .handled
            }
            .overlay(alignment: .topLeading) {
                // Hangs the list just below the row, over whatever follows it.
                if isShowing {
                    GeometryReader { row in
                        list.offset(y: row.size.height)
                    }
                }
            }
            .zIndex(isShowing ? 2 : 0)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { choose(suggestion) } label: {
                    HStack(spacing: 6) {
                        if !suggestion.name.isEmpty { Text(suggestion.name).lineLimit(1) }
                        Text(suggestion.email).foregroundStyle(suggestion.name.isEmpty ? .primary : .secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(index == highlighted ? Color.accentColor.opacity(0.25) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.leading, 72)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Contact suggestions")
    }

    private func refresh() async {
        let query = token
        guard isFocused, !query.isEmpty else { suggestions = []; return }
        // Typing restarts this task, so only a pause in typing reaches the database.
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let found = await lookup(query, accountID)
        guard !Task.isCancelled else { return }
        let present = Set(AddressToken.addresses(in: text))
        // An address that is already fully typed has nothing left to complete.
        suggestions = found.filter { !present.contains($0.email.lowercased()) && $0.email.caseInsensitiveCompare(query) != .orderedSame }
        highlighted = 0
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard isShowing else { return .ignored }
        highlighted = (highlighted + step + suggestions.count) % suggestions.count
        return .handled
    }

    private func accept() -> KeyPress.Result {
        guard isShowing, suggestions.indices.contains(highlighted) else { return .ignored }
        choose(suggestions[highlighted])
        return .handled
    }

    private func choose(_ suggestion: ContactSuggestion) {
        text = AddressToken.completing(text, with: suggestion.email)
        suggestions = []
    }
}

nonisolated extension AddressToken {
    /// Lowercased addresses already complete before the one being typed, so they are not suggested twice.
    static func addresses(in text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: false).dropLast().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

extension View {
    /// Offers addresses from the account's mail while the last address in `text` is being typed.
    func contactSuggestions(for text: Binding<String>, isFocused: Bool, accountID: String?,
                            lookup: @escaping ContactLookup) -> some View {
        modifier(ContactSuggestionsModifier(text: text, isFocused: isFocused, accountID: accountID, lookup: lookup))
    }
}
