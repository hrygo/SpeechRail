import SwiftUI

public struct CreatorSurfaceView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                PageIntroView(route: route)
                creatorContent
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .toolbar {
            ToolbarItem {
                ServiceStatusBadge()
            }
        }
    }

    @ViewBuilder
    private var creatorContent: some View {
        switch route {
        case .dubbing:
            DubbingDeskView()
        case .voiceDesign:
            VoiceDesignView()
        case .voiceLibrary:
            VoiceLibraryView()
        case .works:
            WorksView()
        case .overview, .monitoring, .models, .diagnostics:
            EmptyView()
        }
    }
}

public struct DubbingDeskView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("把文本变成声音")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            TextEditor(text: .constant("在这里粘贴需要配音的文本。选择音色后，可以在服务就绪时生成预览。"))
                .font(SpeechRailDesignTokens.Typography.body)
                .frame(minHeight: SpeechRailDesignTokens.Layout.creatorComposerMinimumHeight)
                .padding(SpeechRailDesignTokens.Spacing.xs)
                .speechRailSurface(.control)
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Picker("音色", selection: .constant("晨光")) {
                    Text("晨光").tag("晨光")
                    Text("松风").tag("松风")
                }
                .frame(width: SpeechRailDesignTokens.Layout.creatorVoicePickerWidth)
                Button("生成预览") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .help("服务模块接入后可生成音频预览")
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
    }
}

public struct VoiceDesignView: View {
    @State private var description = "温暖、清晰、亲近，像一位耐心的播客主持人。"

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
                    Text("从一句话开始")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    Text("先描述你想要的声音，再试听候选并保存。")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                }
                Spacer()
                Text("保留的产品主线")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.voiceAccent)
            }
            TextEditor(text: $description)
                .font(SpeechRailDesignTokens.Typography.body)
                .frame(minHeight: SpeechRailDesignTokens.Layout.creatorComposerMinimumHeight)
                .padding(SpeechRailDesignTokens.Spacing.xs)
                .speechRailSurface(.control)
                .accessibilityLabel("音色描述")
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text("建议：温暖 · 清晰 · 自然语速")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                Spacer()
                Button("生成候选音色") {}
                    .buttonStyle(.borderedProminent)
                    .tint(SpeechRailDesignTokens.Palette.voiceAccent)
                    .disabled(true)
                    .help("服务模块接入后生成候选音色")
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
    }
}

public struct VoiceLibraryView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("已保存的声音")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            ContentUnavailableView {
                Label("还没有保存的音色", systemImage: "waveform")
            } description: {
                Text("完成一次音色创作并保存后，音色会出现在这里。")
            } actions: {
                Button("打开音色创作") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight)
        .speechRailContentSurface()
    }
}

public struct WorksView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("最近的作品")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            ContentUnavailableView {
                Label("还没有作品", systemImage: "folder")
            } description: {
                Text("在配音台生成并保存结果后，可以在这里继续查看。")
            } actions: {
                Button("打开配音台") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight)
        .speechRailContentSurface()
    }
}
