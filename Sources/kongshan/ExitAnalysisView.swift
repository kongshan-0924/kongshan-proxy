import KongshanCore
import SwiftUI

/// 出口分析页。把「这是个什么 IP」和「这个 IP 现在到底能不能用」放在一起。
///
/// 后者是这一页存在的理由：真机 2026-09-03～09-04，Codex 反复「正在重新连接」的真因是
/// Cloudflare 对当前出口 IP 回 403 + `cf-mitigated: challenge`，而界面上只显示"超时"，
/// 用户以为节点全死了、反复换节点也没用。有了这一页，换节点前就能判断值不值得换。
struct ExitAnalysisView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                exitGroup
                reachabilityGroup
                dnsGroup
            }
            .padding(20)
        }
        .navigationTitle("出口分析")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await state.refreshSiteProbes() }
                } label: {
                    Label("重新自测", systemImage: "checkmark.shield")
                }
                .disabled(state.isProbingSites)
                .help("直接请求这些站点，看当前出口会不会被拦")

                Button {
                    Task { await state.refreshExitDiagnostics() }
                } label: {
                    Label("刷新出口", systemImage: "arrow.clockwise")
                }
                .disabled(state.isRefreshingExitDiagnostics)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainTextReport, forType: .string)
                } label: {
                    Label("复制报告", systemImage: "doc.on.doc")
                }
                .help("复制成纯文本，便于反馈问题时贴出来")
            }
        }
        .onAppear {
            if state.isOn, state.exitDiagnostics == nil {
                Task { await state.refreshExitDiagnostics() }
            }
        }
    }

    private var subtitle: String {
        guard let report = state.exitDiagnostics else {
            return state.isOn ? "尚未检测" : "代理未开启，检测的是本机直连出口"
        }
        return report.exit.location
    }

    // MARK: - 出口

    private var exitGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                header("出口 IP", symbol: "globe.asia.australia", tint: .orange)
                if let report = state.exitDiagnostics {
                    // IP 要能选中复制：用户去查询、去反馈时都需要它。
                    row("IP 地址", value: report.exit.ip, monospaced: true, selectable: true)
                    row("位置", value: report.exit.location)
                    row("归属", value: report.exit.organization.isEmpty ? "未知" : report.exit.organization)
                    row("检测于", value: report.checkedAt.formatted(date: .omitted, time: .standard))
                } else if state.isRefreshingExitDiagnostics {
                    ProgressView().controlSize(.small)
                } else {
                    emptyHint(state.exitDiagnosticsError ?? "点右上角「刷新出口」开始检测")
                }
            }
            .padding(4)
        }
    }

    // MARK: - 站点可达性

    private var reachabilityGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                header("站点可达性", symbol: "checkmark.shield", tint: .blue)
                Text("直接请求这些站点看真实结果。比第三方「IP 风险分」准，也不必把你的出口 IP 交给额外的服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = state.siteProbeSummary {
                    Text(summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if state.siteProbes.isEmpty {
                    if state.isProbingSites {
                        ProgressView().controlSize(.small)
                    } else {
                        emptyHint("点右上角「重新自测」开始")
                    }
                } else {
                    ForEach(state.siteProbes) { result in
                        probeRow(result)
                    }
                    if let checkedAt = state.siteProbesCheckedAt {
                        Text("自测于 \(checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(4)
        }
    }

    private func probeRow(_ result: SiteProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint(for: result.outcome))
                    .frame(width: 7, height: 7)
                Text(result.target.name)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if let ms = result.elapsedMilliseconds {
                    Text("\(ms) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(label(for: result.outcome))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint(for: result.outcome))
            }
            Text(result.target.impact)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func label(for outcome: SiteProbeOutcome) -> String {
        switch outcome {
        case let .ok(code): "可达（\(code)）"
        case let .challenged(code, _): "需人机验证（\(code)）"
        case let .rejected(code): "被拒（\(code)）"
        case .failed: "连不上"
        }
    }

    private func tint(for outcome: SiteProbeOutcome) -> Color {
        switch outcome {
        case .ok: .green
        case .challenged: .orange
        case .rejected, .failed: .red
        }
    }

    // MARK: - DNS

    private var dnsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                header("DNS 泄漏", symbol: "list.bullet.rectangle", tint: .teal)
                if let report = state.exitDiagnostics {
                    HStack(spacing: 6) {
                        Circle().fill(dnsTint(report.dns.status)).frame(width: 7, height: 7)
                        Text(dnsTitle(report.dns.status))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(dnsTint(report.dns.status))
                    }
                    Text(report.dns.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if report.resolvers.isEmpty {
                        emptyHint("没有探测到解析器")
                    } else {
                        // 解析器明细此前拿到了却从未展示。判断泄漏时，用户需要看到"到底是谁在解析"。
                        Divider()
                        Text("实际使用的解析器（\(report.resolvers.count) 个）")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(report.resolvers) { resolver in
                            HStack(spacing: 8) {
                                Text(resolver.ip)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text(resolverLocation(resolver))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                if resolver.isMullvadDNS {
                                    Text("检测服务自有")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } else {
                    emptyHint("出口检测完成后才有 DNS 结论")
                }
            }
            .padding(4)
        }
    }

    private func resolverLocation(_ resolver: DNSResolverInfo) -> String {
        let place = [resolver.city, resolver.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let org = resolver.organization
        return [place, org].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func dnsTitle(_ status: DNSLeakStatus) -> String {
        switch status {
        case .clear: "未发现明显泄漏"
        case .possible: "可能泄漏"
        case .indeterminate: "无法判断"
        }
    }

    private func dnsTint(_ status: DNSLeakStatus) -> Color {
        switch status {
        case .clear: .green
        case .possible: .orange
        case .indeterminate: .secondary
        }
    }

    // MARK: - 通用

    private func header(_ title: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private func row(
        _ title: String,
        value: String,
        monospaced: Bool = false,
        selectable: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(monospaced ? .callout.monospaced() : .callout)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 纯文本报告。反馈问题时贴这一段，比截图更有用。
    var plainTextReport: String {
        var lines: [String] = ["kongshan 出口分析"]
        if let report = state.exitDiagnostics {
            lines.append("出口 IP：\(report.exit.ip)")
            lines.append("位置：\(report.exit.location)")
            lines.append("归属：\(report.exit.organization)")
            lines.append("DNS：\(dnsTitle(report.dns.status))——\(report.dns.detail)")
            if !report.resolvers.isEmpty {
                lines.append("解析器：" + report.resolvers.map(\.ip).joined(separator: "、"))
            }
        }
        if !state.siteProbes.isEmpty {
            lines.append("站点可达性：")
            for result in state.siteProbes {
                let ms = result.elapsedMilliseconds.map { " \($0) ms" } ?? ""
                lines.append("  - \(result.target.name)：\(label(for: result.outcome))\(ms)")
            }
        }
        if let summary = state.siteProbeSummary { lines.append("结论：\(summary)") }
        return lines.joined(separator: "\n")
    }
}
