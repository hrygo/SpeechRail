import Foundation
import SpeechRailControlKit

/// 一个角色绑定到哪个声音。
///
/// `voiceName` 是绑定当时的显示名，只用于「音色已被删除」这类提示；
/// 判断声音是否变了看 `voiceID`，判断声学身份是否变了看 `voiceRevision`。
public struct DubbingVoiceBinding: Codable, Equatable, Hashable, Sendable {
    public let voiceID: String
    public let voiceName: String
    public let voiceRevision: String?
    public let mode: String?

    public init(voiceID: String, voiceName: String, voiceRevision: String? = nil, mode: String? = nil) {
        self.voiceID = voiceID
        self.voiceName = voiceName
        self.voiceRevision = voiceRevision
        self.mode = mode
    }
}

/// 某个角色第一次成功渲染时观察到的事实。
///
/// 为什么按角色记而不按项目记：克隆音色走 Base、设计音色走 VoiceDesign，
/// 两个角色的模型 artifact 本来就可以不同。按项目记会把合法的多模型项目
/// 判成「运行版本变了」。
///
/// `voiceRevision` 也记在里面：它是这次渲染真正用到的声学身份，
/// 和角色绑定当时的 revision 可能不同——音色被改过之后，
/// 旧候选必须失效，而不是继续被当成同一个声音。
public struct DubbingRenderRuntime: Codable, Equatable, Sendable {
    public let engineRevision: String?
    public let modelArtifact: String?
    public let modelArtifactRevision: String?
    public let voiceRevision: String?
    public let sampleRate: Int?
    public let channels: Int?

    public init(
        engineRevision: String?,
        modelArtifact: String?,
        modelArtifactRevision: String?,
        voiceRevision: String?,
        sampleRate: Int?,
        channels: Int?
    ) {
        self.engineRevision = engineRevision
        self.modelArtifact = modelArtifact
        self.modelArtifactRevision = modelArtifactRevision
        self.voiceRevision = voiceRevision
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// 没有完整配方摘要时不产生运行事实：宁可拒绝比较，也不拿半份事实下结论。
    public init?(recipe: RenderRecipeSnapshot?) {
        guard let recipe, recipe.digest != nil else { return nil }
        self.init(
            engineRevision: recipe.engineRevision,
            modelArtifact: recipe.modelArtifact,
            modelArtifactRevision: recipe.modelArtifactRevision,
            voiceRevision: recipe.voiceRevision,
            sampleRate: recipe.sampleRate,
            channels: recipe.channels
        )
    }
}

/// 脚本里的一个角色。`voice == nil` 表示「还没选声音」，是一个必须显式处理的状态，
/// 不是「默认用某个声音」——静默换声正是这个功能要避免的事。
public struct DubbingRole: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameLength = 24

    public let id: String
    public var name: String
    public var voice: DubbingVoiceBinding?
    /// 第一次成功渲染后固定；之后这个角色的候选都要和它对得上。
    public var runtime: DubbingRenderRuntime?
    /// 这个角色的语速。参考音色（clone）只支持 1.0x，由调用方在渲染前校验。
    public var speed: Double

    public init(
        id: String,
        name: String,
        voice: DubbingVoiceBinding? = nil,
        runtime: DubbingRenderRuntime? = nil,
        speed: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.voice = voice
        self.runtime = runtime
        self.speed = speed
    }
}

/// 句间停顿。停顿由客户端在装配时插入静音，绝不作为控制标记送进模型。
public enum DubbingPause {
    public static let maximumMilliseconds = 5_000
    public static let stepMilliseconds = 100
    /// 常用档位：0 到 2 秒。用户仍可用步进调到 5 秒。
    public static let presets = [0, 200, 400, 800, 1_200, 2_000]

    public static func clamped(_ milliseconds: Int) -> Int {
        min(max(milliseconds, 0), maximumMilliseconds)
    }

    public static func label(_ milliseconds: Int) -> String {
        let clamped = clamped(milliseconds)
        guard clamped > 0 else { return "无停顿" }
        return String(format: "停顿 %.1f 秒", Double(clamped) / 1_000)
    }

    /// 单声道 16 bit 线性 PCM 下这段停顿占多少字节。
    public static func byteCount(milliseconds: Int, sampleRate: Int) -> Int {
        guard milliseconds > 0, sampleRate > 0 else { return 0 }
        // 每毫秒 sampleRate/1000 个采样，先乘后除避免整数截断累积。
        return clamped(milliseconds) * sampleRate / 1_000 * 2
    }
}

/// 角色表的问题。提示必须指向用户能修的方向：换声音、重建角色、重新绑定。
public enum DubbingCastIssue: Equatable, Sendable {
    case voiceUnassigned(roleID: String, roleName: String)
    case voiceMissing(roleID: String, roleName: String, voiceName: String)
    case voiceUnavailable(roleID: String, roleName: String, voiceName: String)
    case voiceRevisionChanged(roleID: String, roleName: String, voiceName: String)

    public var roleID: String {
        switch self {
        case .voiceUnassigned(let id, _), .voiceMissing(let id, _, _),
             .voiceUnavailable(let id, _, _), .voiceRevisionChanged(let id, _, _):
            id
        }
    }

    public var message: String {
        switch self {
        case .voiceUnassigned(_, let roleName):
            "「\(roleName)」还没有选声音，这一角色的段落无法生成。"
        case .voiceMissing(_, let roleName, let voiceName):
            "「\(roleName)」绑定的音色「\(voiceName)」已不在音色库里，请重新选声音。"
        case .voiceUnavailable(_, let roleName, let voiceName):
            "「\(roleName)」绑定的音色「\(voiceName)」当前不可用，请换一个或稍后重试。"
        case .voiceRevisionChanged(_, let roleName, let voiceName):
            "「\(roleName)」绑定的音色「\(voiceName)」已变化，之前生成的段落需要重新生成。"
        }
    }
}

/// 角色与音色的对账。只看事实，不猜。
public enum DubbingCastAudit {
    /// 需要用户处理的角色问题，按角色顺序返回。
    public static func issues(
        cast: [DubbingRole],
        voices: [CreatorVoice],
        voicesLoadState: CreatorVoicesLoadState
    ) -> [DubbingCastIssue] {
        // 列表还没读到不等于音色没了：这时不做任何判断，避免把「未知」说成「坏了」。
        guard voicesLoadState == .loaded else { return [] }
        var issues: [DubbingCastIssue] = []
        for role in cast {
            guard let binding = role.voice else {
                issues.append(.voiceUnassigned(roleID: role.id, roleName: role.name))
                continue
            }
            guard let voice = voices.first(where: { $0.id == binding.voiceID }) else {
                issues.append(
                    .voiceMissing(roleID: role.id, roleName: role.name, voiceName: binding.voiceName)
                )
                continue
            }
            guard voice.available else {
                issues.append(
                    .voiceUnavailable(
                        roleID: role.id, roleName: role.name, voiceName: binding.voiceName
                    )
                )
                continue
            }
            // 只有两边都记了 revision 才比较；缺一边就是无从判断，不当成变化。
            if let bound = binding.voiceRevision, let current = voice.revision, bound != current {
                issues.append(
                    .voiceRevisionChanged(
                        roleID: role.id, roleName: role.name, voiceName: binding.voiceName
                    )
                )
            }
        }
        return issues
    }
}

/// 角色表本身的不变量。改名、加角色、删角色都要先过这里。
public enum DubbingCastRules {
    public static func normalizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(DubbingRole.maximumNameLength))
    }

    /// 返回校验后的角色表；名字为空或重名直接拒绝，不做静默去重。
    public static func validate(_ cast: [DubbingRole]) throws -> [DubbingRole] {
        var seen = Set<String>()
        var normalized: [DubbingRole] = []
        for role in cast {
            guard DubbingProjectStore.isSafeIdentifier(role.id) else {
                throw DubbingProjectError.invalidIdentifier
            }
            let name = normalizedName(role.name)
            guard !name.isEmpty else { throw DubbingProjectError.roleNameEmpty }
            guard seen.insert(name).inserted else { throw DubbingProjectError.roleNameDuplicate }
            // 语速边界也是角色表不变量：越界值与空名一样是自相矛盾的数据，不是可以悄悄夹住的输入。
            guard role.speed >= 0.5, role.speed <= 2.0 else {
                throw DubbingProjectError.roleSpeedOutOfRange
            }
            var copy = role
            copy.name = name
            copy.speed = role.voice?.mode == "clone" ? 1.0 : role.speed
            normalized.append(copy)
        }
        return normalized
    }

    public static func newRoleID(existing: [DubbingRole]) -> String {
        var index = existing.count + 1
        let taken = Set(existing.map(\.id))
        while taken.contains("role_\(index)") { index += 1 }
        return "role_\(index)"
    }

    /// 新角色的默认名：「角色 1」「角色 2」，跳过已占用的名字。
    public static func newRoleName(existing: [DubbingRole]) -> String {
        let taken = Set(existing.map(\.name))
        var index = existing.count + 1
        while taken.contains("角色 \(index)") { index += 1 }
        return "角色 \(index)"
    }
}
