import Foundation

/// T07：语义依赖快照与精确失效集合计算。
/// 规则：
/// - 角色改显示名或改别称：dependencyDigest 不变，失效集合为空；
/// - 单句改说话人归属：仅包含受该句影响的旧/新片段 ID；
/// - 某角色更换音色或音色版本：仅包含该角色的所有片段 ID；
/// - 全局模型版本或合成策略变更：包含所有受影响的片段 ID。
public struct AudiobookDependencySnapshot: Codable, Equatable, Sendable {
    public var sourceSHA256: String
    public var fragments: [AudiobookFragment]
    public var characterNamesByRoleID: [UUID: String]
    public var characterAliasesByRoleID: [UUID: [String]]

    public init(
        sourceSHA256: String,
        fragments: [AudiobookFragment],
        characterNamesByRoleID: [UUID: String] = [:],
        characterAliasesByRoleID: [UUID: [String]] = [:]
    ) {
        self.sourceSHA256 = sourceSHA256
        self.fragments = fragments
        self.characterNamesByRoleID = characterNamesByRoleID
        self.characterAliasesByRoleID = characterAliasesByRoleID
    }
}

public enum AudiobookInvalidation {
    public static func affectedFragments(
        before: AudiobookDependencySnapshot,
        after: AudiobookDependencySnapshot
    ) -> Set<UUID> {
        if before.sourceSHA256 != after.sourceSHA256 {
            return Set(before.fragments.map(\.id)).union(after.fragments.map(\.id))
        }

        // 极端输入下同一区间可能出现多个片段；按区间分组而不是 uniqueKeysWithValues，
        // 避免快照差异计算因重复键直接崩溃。
        let beforeByRange = Dictionary(grouping: before.fragments, by: \.sourceRange)
            .compactMapValues(\.first)
        let afterByRange = Dictionary(grouping: after.fragments, by: \.sourceRange)
            .compactMapValues(\.first)

        var invalidated = Set<UUID>()

        for oldFrag in before.fragments {
            if let matchingNew = afterByRange[oldFrag.sourceRange] {
                if oldFrag.dependencyDigest != matchingNew.dependencyDigest {
                    invalidated.insert(oldFrag.id)
                    invalidated.insert(matchingNew.id)
                }
            } else {
                // Range boundary changed due to speaker reassignment splitting/merging a fragment
                invalidated.insert(oldFrag.id)
            }
        }

        for newFrag in after.fragments {
            if beforeByRange[newFrag.sourceRange] == nil {
                invalidated.insert(newFrag.id)
            }
        }

        return invalidated
    }
}
