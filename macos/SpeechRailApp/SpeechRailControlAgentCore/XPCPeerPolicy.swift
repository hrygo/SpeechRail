import Foundation

public struct XPCPeerPolicy: Sendable, Equatable {
    public let requirement: String

    public init(requirement: String) {
        self.requirement = requirement
    }

    public init(teamIdentifier: String, appIdentifier: String) {
        let teamCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        )
        let identifierCharacters = teamCharacters.union(CharacterSet(charactersIn: ".-"))
        guard let team = Self.normalized(teamIdentifier, allowedCharacters: teamCharacters),
              let identifier = Self.normalized(
                  appIdentifier,
                  allowedCharacters: identifierCharacters
              )
        else {
            self.requirement = ""
            return
        }
        self.requirement =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    public init(developmentAppIdentifier: String) {
        let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"
        )
        guard let identifier = Self.normalized(
            developmentAppIdentifier,
            allowedCharacters: allowedCharacters
        ) else {
            self.requirement = ""
            return
        }
        self.requirement = "identifier \"\(identifier)\""
    }

    public var isConfigured: Bool {
        !requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalized(
        _ rawValue: String,
        allowedCharacters: CharacterSet
    ) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
        else {
            return nil
        }
        return value
    }
}
