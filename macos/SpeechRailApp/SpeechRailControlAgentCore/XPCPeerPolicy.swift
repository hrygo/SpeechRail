import Foundation

public struct XPCPeerPolicy: Sendable, Equatable {
    public let requirement: String

    public init(requirement: String) {
        self.requirement = requirement
    }

    public init(teamIdentifier: String, appIdentifier: String) {
        let team = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty, !identifier.isEmpty else {
            self.requirement = ""
            return
        }
        self.requirement =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    public var isConfigured: Bool {
        !requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
