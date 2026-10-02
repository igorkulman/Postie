import Foundation

/// Marks one run of something (a folder's contents, an open conversation, an account's session).
/// Advancing it invalidates every piece of in-flight work that remembered the old value.
struct Generation: Equatable {
    private var value = 0
    mutating func advance() { value &+= 1 }
}
