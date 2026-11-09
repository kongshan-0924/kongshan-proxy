import KongshanCore
import SwiftUI

/// 出口分析小窗组：「出口 IP」「IP 风险」「DNS」三张，外加站点可达性（`SiteReachabilityCard`）。
///
/// 这一组小窗存在的理由是「这个 IP 现在到底能不能用」：真机 2026-09-03～09-04，Codex 反复
/// 「正在重新连接」的真因是 Cloudflare 对当前出口 IP 回 403 + `cf-mitigated: challenge`，
/// 而界面上只显示"超时"，用户以为节点全死了、反复换节点也没用。有了这组小窗，换节点前就能判断值不值得换。
///
/// 2026-11-06 起诊断页合并成一页：本视图不再自带页面容器、工具栏与整页空态，
/// ⌘R「全部重新检测」与「复制报告」挪到诊断页工具栏。诊断页把它与其余四张诊断小窗
/// 放进同一个瀑布流：出口三卡作为整体单元（内部竖叠），单元之间按最矮列放置，
/// 矮卡下方不再留空。独立构造 `ExitAnalysisView()` 仍渲染出口三卡，
/// 供 RenderSnapshotTests / SidebarShortcutTests 使用。
struct ExitAnalysisView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.cardGap) {
            ExitIPCard()
            ExitDNSCard()
        }
    }

    /// 两项检测一起跑：站点自测和出口检测互不依赖，串行等一个再等一个只是让用户多等。
    static func runFullCheck(state: AppState) {
        Task {
            async let exit: Void = state.refreshExitDiagnostics()
            async let probes: Void = state.refreshSiteProbes()
            _ = await (exit, probes)
        }
    }

    /// 纯文本报告。反馈问题时贴这一段，比截图更有用；诊断页工具栏的「复制报告」也用它。
    static func plainTextReport(state: AppState) -> String {
        var lines: [String] = ["kongshan 出口分析"]
        if let report = state.exitDiagnostics {
            lines.append("出口 IP：\(report.exit.ip)")
            lines.append("位置：\(report.exit.location)")
            lines.append("归属：\(report.exit.organization)")
            if let reputation = report.reputation {
                if let asn = reputation.asnText { lines.append("ASN：\(asn)") }
                let summary = Theme.riskSummary(reputation)
                if !summary.isEmpty { lines.append("风险评估：\(summary)（来源 \(IPReputationService.sourceName)）") }
            }
            lines.append("DNS：\(dnsStatusTitle(report.dns.status))——\(report.dns.detail)")
            if !report.resolvers.isEmpty {
                lines.append("解析器：" + report.resolvers.map(\.ip).joined(separator: "、"))
            }
        }
        if !state.siteProbes.isEmpty {
            lines.append("站点可达性：")
            for result in state.siteProbes {
                let ms = result.elapsedMilliseconds.map { " \($0) ms" } ?? ""
                lines.append("  - \(result.target.name)：\(probeOutcomeLabel(result.outcome))\(ms)")
            }
        }
        if let summary = state.siteProbeSummary { lines.append("结论：\(summary)") }
        return lines.joined(separator: "\n")
    }
}

/// 出口 IP 小窗：无论是否检测过都在——合并成一页后，这块不能再整段消失只剩一张空卡。
struct ExitIPCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TileCard("出口 IP", symbol: "globe.asia.australia", height: nil) {
            if let report = state.exitDiagnostics {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(report.exit.ip)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.exit.ip, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("拷贝出口 IP")
                    }

                    Theme.separator.frame(height: 0.5)

                    kvRow(label: "位置", value: report.exit.location)
                    kvRow(label: "归属", value: report.exit.organization.isEmpty ? "未知" : report.exit.organization)
                    if let asn = report.reputation?.asnText {
                        kvRow(label: "ASN", value: asn)
                    }
                    kvRow(label: "检测时间", value: report.checkedAt.formatted(date: .omitted, time: .standard))

                    if let reputation = report.reputation,
                       let score = reputation.fraudScore,
                       let risk = reputation.risk {
                        Theme.separator.frame(height: 0.5)

                        HStack(alignment: .center, spacing: 8) {
                            Text("IP 风险")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 72, alignment: .leading)

                            Text("\(score)%")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.riskStyle(risk).text)

                            Text(risk.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.riskStyle(risk).text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Theme.riskStyle(risk).soft, in: Capsule(style: .circular))

                            if !reputation.labels.isEmpty {
                                Text(reputation.labels.joined(separator: " · "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }

                        CapacityBar(fraction: Double(score) / 100, tint: Theme.riskStyle(risk).icon, height: 4)
                            .accessibilityLabel("风险评分")
                            .accessibilityValue("\(score) 分，满分 100")

                        Text("来源 \(IPReputationService.sourceName) / 仅作参考")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 8)
            } else if state.isRefreshingExitDiagnostics {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检测出口…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 16)
            } else if let error = state.exitDiagnosticsError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await state.refreshExitDiagnostics() } }
                }
                .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("—")
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    Text(state.isOn ? "检测出口归属、风险、DNS 与站点可达性。" : "代理未开启，测到的是本机直连出口。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                Button("立即检测") { ExitAnalysisView.runFullCheck(state: state) }
                    .buttonStyle(.pillProminent)
                    .padding(.bottom, 8)
            }
        }
    }

    private func kvRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// IP 风险小窗：分数条、等级、标签；无数据时占位而不是整卡消失。
struct ExitRiskCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TileCard("IP 风险", symbol: "shield.lefthalf.filled", height: nil) {
            if let reputation = state.exitDiagnostics?.reputation,
               reputation.fraudScore != nil || !reputation.labels.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if let score = reputation.fraudScore, let risk = reputation.risk {
                        HStack(spacing: 10) {
                            Text("\(score)%")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.riskStyle(risk).text)
                            Text(risk.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.riskStyle(risk).text)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Theme.riskStyle(risk).soft, in: Capsule(style: .circular))
                            Spacer(minLength: 8)
                        }
                        CapacityBar(fraction: Double(score) / 100, tint: Theme.riskStyle(risk).icon, height: 5)
                            .accessibilityLabel("风险评分")
                            .accessibilityValue("\(score) 分，满分 100")
                    }

                    HStack(spacing: 8) {
                        if !reputation.labels.isEmpty {
                            WrappingRiskLabels(labels: reputation.labels)
                        }
                        Spacer()
                        Text("来源 \(IPReputationService.sourceName) / 仅作参考")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 8)
            } else {
                TileEmptyNote(text: "检测后显示")
            }
        }
    }
}

/// DNS 小窗：解析器列表与泄漏结论；无数据时占位。
struct ExitDNSCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TileCard(
            "DNS", symbol: "list.bullet.rectangle",
            detail: state.exitDiagnostics.map { "\($0.resolvers.count) 个解析器" },
            height: nil
        ) {
            if let report = state.exitDiagnostics {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(dnsStatusStyle(report.dns.status).icon).frame(width: 7, height: 7)
                        Text(dnsStatusTitle(report.dns.status))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(dnsStatusStyle(report.dns.status).text)
                        Spacer(minLength: 0)
                    }
                    Text(report.dns.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)

                if report.resolvers.isEmpty {
                    TileEmptyNote(text: "没有探测到解析器")
                } else {
                    ForEach(report.resolvers) { resolver in
                        HStack(spacing: 8) {
                            Image(systemName: "network")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                            Text(resolver.ip)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(resolverLocation(resolver))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 4)
                        if resolver.id != report.resolvers.last?.id {
                            Theme.separator.frame(height: 0.5)
                        }
                    }
                }
            } else {
                TileEmptyNote(text: "出口检测完成后才有 DNS 结论")
            }
        }
    }
}

/// 站点可达性小窗：直接请求站点，核对真实可用性。
/// 没检测时也把站点列出来（结果写「未检测」）：小窗不留空，也知道会测哪些。
struct SiteReachabilityCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TileCard(
            "站点可达性", symbol: "checkmark.shield",
            detail: state.siteProbesCheckedAt.map { "测于 \($0.formatted(date: .omitted, time: .shortened))" },
            height: nil
        ) {
            EmptyView()
        } fixedHeader: {
            VStack(alignment: .leading, spacing: 4) {
                Text("直接请求站点，核对真实可用性。比第三方 IP 风险分更接近真实结果，也不必把出口 IP 交给额外服务。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = state.siteProbeSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(summaryTint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(summary)
                }
            }
        } content: {
            if state.siteProbes.isEmpty {
                if state.isProbingSites {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在检测站点…")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 16)
                } else {
                    ForEach(SiteReachabilityProbe.defaultTargets) { target in
                        untestedRow(target, showsDivider: target.id != SiteReachabilityProbe.defaultTargets.last?.id)
                    }
                }
            } else {
                ForEach(state.siteProbes) { result in
                    probeRow(result, showsDivider: result.id != state.siteProbes.last?.id)
                }
            }
        }
    }

    private var summaryTint: Color {
        state.siteProbes.contains { if case .challenged = $0.outcome { return true } else { return false } }
            ? Theme.warning.text : Theme.textSecondary
    }

    private func probeRow(_ result: SiteProbeResult, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(probeOutcomeStyle(result.outcome).icon)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.target.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(result.target.impact)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    if let ms = result.elapsedMilliseconds {
                        Text("\(ms) ms")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(probeOutcomeLabel(result.outcome))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(probeOutcomeStyle(result.outcome).text)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            .padding(.vertical, 7)
            if showsDivider {
                Theme.separator.frame(height: 0.5)
            }
        }
    }

    private func untestedRow(_ target: SiteProbeTarget, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.textTertiary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(target.impact)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("未检测")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 7)
            if showsDivider {
                Theme.separator.frame(height: 0.5)
            }
        }
    }
}

// MARK: - 共享的判定与文案（小窗与纯文本报告共用）

private func resolverLocation(_ resolver: DNSResolverInfo) -> String {
    let place = [resolver.city, resolver.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    let org = resolver.organization
    return [place, org].filter { !$0.isEmpty }.joined(separator: " · ")
}

private func dnsStatusTitle(_ status: DNSLeakStatus) -> String {
    switch status {
    case .clear: "未发现明显泄漏"
    case .possible: "可能泄漏"
    case .indeterminate: "无法判断"
    }
}

private func dnsStatusStyle(_ status: DNSLeakStatus) -> Theme.SemanticColors {
    switch status {
    case .clear: Theme.success
    case .possible: Theme.warning
    case .indeterminate: Theme.neutral
    }
}

private func probeOutcomeLabel(_ outcome: SiteProbeOutcome) -> String {
    switch outcome {
    case let .ok(code): "可达（\(code)）"
    case let .challenged(code, _): "需人机验证（\(code)）"
    case let .rejected(code): "被拒（\(code)）"
    case .failed: "连不上"
    }
}

private func probeOutcomeStyle(_ outcome: SiteProbeOutcome) -> Theme.SemanticColors {
    switch outcome {
    case .ok: Theme.success
    case .challenged: Theme.warning
    case .rejected, .failed: Theme.danger
    }
}

/// 风险标签可能不止一个；窄列中换行展示，不用横向滚动或截断状态信息。
private struct WrappingRiskLabels: View {
    let labels: [String]

    var body: some View {
        // 服务端标签通常只有一两个；这里用横向流式布局的思路保留全部文字，避免为了排版引入新状态。
        VStack(alignment: .leading, spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.controlFill, in: Capsule(style: .circular))
            }
        }
    }
}
