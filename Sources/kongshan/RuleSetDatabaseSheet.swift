import KongshanCore
import SwiftUI

/// GeoIP / 规则集数据库。迁自 设置→资源。
///
/// 规则集就是规则页的数据源——用户想「更新规则库」时不会先想到设置。
/// 用 sheet 而不是规则页上的常驻分区：规则页已经迁入了「强制直连与排除」，
/// 再加一个常驻分区会继续增胖。
///
/// 开关文案是「**规则集**自动更新」而不是裸「自动更新」：配置页还有一个管订阅的
/// 「启用自动更新」，两个不同对象的同名开关在用户心智里会撞车。
struct RuleSetDatabaseSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("下载源", selection: mirrorBinding) {
                        ForEach(RuleSetMirror.allCases, id: \.self) { mirror in
                            Text(mirror.displayName).tag(mirror)
                        }
                    }
                    Toggle("规则集自动更新", isOn: autoUpdateBinding)
                    LabeledContent("最后更新", value: lastRuleSetUpdateText)
                    HStack {
                        if state.isUpdatingRuleSets {
                            ProgressView().controlSize(.small)
                            Text("正在更新…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("立即更新") {
                            Task { await state.updateRuleSetsNow() }
                        }
                        .disabled(state.isUpdatingRuleSets)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(
                            RuleSetService.sourceURLs(
                                mirror: state.ruleSetSettings.mirror,
                                includeAds: state.routingSettings.blockAds
                            ),
                            id: \.tag
                        ) { source in
                            Text(source.url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    Text("上游是 sing-box 官方开源仓库 SagerNet/sing-geoip 与 sing-geosite，由官方持续维护。下载后用打包内核校验通过才替换缓存；失败或关闭自动更新时沿用最后一次成功的缓存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 420)
    }

    private var mirrorBinding: Binding<RuleSetMirror> {
        Binding(
            get: { state.ruleSetSettings.mirror },
            set: { mirror in
                var settings = state.ruleSetSettings
                settings.mirror = mirror
                Task { await state.setRuleSetSettings(settings) }
            }
        )
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { state.ruleSetSettings.autoUpdate },
            set: { enabled in
                var settings = state.ruleSetSettings
                settings.autoUpdate = enabled
                Task { await state.setRuleSetSettings(settings) }
            }
        )
    }

    private var lastRuleSetUpdateText: String {
        state.ruleSetSettings.lastUpdatedAt?
            .formatted(date: .abbreviated, time: .shortened) ?? "尚未更新"
    }
}
