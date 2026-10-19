import Foundation

/// The `uses` edges of one problem's statements, for the cycle check and for what a statement may still use.
nonisolated struct UsesGraph: Hashable, Sendable {
    private let uses: [UUID: [UUID]]
    private let users: [UUID: [UUID]]

    init(uses: [UUID: [UUID]]) {
        self.uses = uses
        var users: [UUID: [UUID]] = [:]
        for user in uses.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for dependency in uses[user] ?? [] { users[dependency, default: []].append(user) }
        }
        self.users = users
    }

    func uses(of id: UUID) -> [UUID] { uses[id] ?? [] }
    func users(of id: UUID) -> [UUID] { users[id] ?? [] }

    /// Everything that uses `id`, directly or through other statements.
    func ancestors(of id: UUID) -> Set<UUID> {
        var found = Set<UUID>()
        var stack = [id]
        while let node = stack.popLast() {
            for user in users(of: node) where found.insert(user).inserted { stack.append(user) }
        }
        return found
    }

    /// The cycle that "`user` uses `dependency`" would close, as `[user, dependency, …, user]`, or nil if it
    /// closes none. A statement using itself gives `[user, user]`.
    func cyclePath(adding user: UUID, uses dependency: UUID) -> [UUID]? {
        if user == dependency { return [user, user] }
        var parent: [UUID: UUID] = [dependency: dependency]
        var stack = [dependency]
        while let node = stack.popLast() {
            for next in uses(of: node) where parent[next] == nil {
                parent[next] = node
                guard next == user else {
                    stack.append(next)
                    continue
                }
                var path = [user]
                var cursor = user
                while cursor != dependency, let previous = parent[cursor] {
                    path.append(previous)
                    cursor = previous
                }
                return [user] + path.reversed()
            }
        }
        return nil
    }

    /// The statements among `all` that `user` could newly use: not itself, not one it already uses, and not one
    /// that uses it (which would close a cycle). Order is kept.
    func candidates(for user: UUID, among all: [UUID]) -> [UUID] {
        let excluded = ancestors(of: user).union(uses(of: user)).union([user])
        return all.filter { !excluded.contains($0) }
    }
}
