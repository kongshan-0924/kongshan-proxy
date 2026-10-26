import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 手动节点

/// internal 而非 private：由 `NodesView`（另一个文件）以 sheet 呈现。

struct ManualNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @State private var name = ""
    @State private var server = ""
    @State private var port = "443"
    @State private var password = ""
    @State private var sni = ""
    @State private var skipCertificateVerification = false
    @State private var obfsPassword = ""
    @State private var uploadMbps = ""
    @State private var downloadMbps = ""
    @State private var localError: String?
    @State private var mode: Mode = .paste
    @State private var linkText = ""
    @State private var parsed: [ProxyNode] = []
    /// 提交进行中：连点或连按回车不能把同一批节点加两次。
    @State private var isSubmitting = false

    private enum Mode: String, CaseIterable, Identifiable {
        case paste = "粘贴链接"
        case manual = "手动填写"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加自建节点")
                        .font(.headline)
                    Text("保存后会生成独立的“自建”策略组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            CapsuleSegmentedPicker(options: Mode.allCases, selection: $mode) { $0.rawValue }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            if mode == .paste { pasteForm } else { manualForm }

            Divider()
            HStack {
                if mode == .paste, !parsed.isEmpty {
                    Text("将添加 \(parsed.count) 个节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { mode == .paste ? addParsed() : addNode() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.pillProminent)
                    .disabled(isSubmitting || (mode == .paste && parsed.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 470, height: 580)
    }

    // MARK: - 粘贴链接

    private var pasteForm: some View {
        CardForm {
            CardSection {
                TextEditor(text: $linkText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 140)
                    .onChange(of: linkText) { _, _ in reparse() }
                HStack {
                    Button {
                        linkText = NSPasteboard.general.string(forType: .string) ?? ""
                        reparse()
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    Spacer()
                    if !linkText.isEmpty {
                        Button("清空") { linkText = ""; parsed = []; localError = nil }
                            .buttonStyle(.link)
                    }
                }
            } header: {
                Text("分享链接")
            } footer: {
                Text("支持 ss / trojan / vmess / vless / hysteria2(hy2) / anytls。可一次粘贴多行，每行一个；解析不了的行会被跳过。")
            }

            if !parsed.isEmpty {
                CardSection("解析结果") {
                    ForEach(parsed) { node in
                        HStack(spacing: 8) {
                            ProtocolTag(value: node.protocolType)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text("\(node.server):\(String(node.port))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            if let localError {
                CardSection {
                    Label(localError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
    }

    /// 边打边解析。解析是纯字符串处理、无网络无 IO，几十行链接也是微秒级。
    private func reparse() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            parsed = []
            localError = nil
            return
        }
        parsed = NodeShareLink.parseAll(text)
        guard parsed.isEmpty else {
            localError = nil
            return
        }
        // 一个都没解析出来时才报错。整段按单条再试一次，把真实原因带出来——
        // 「端口无效」「不支持的链接类型」远比一句「没有可用链接」有用。
        do {
            _ = try NodeShareLink.parse(text)
            localError = "没有识别到可用的分享链接"
        } catch {
            localError = error.localizedDescription
        }
    }

    private func addParsed() {
        let nodes = parsed
        guard !nodes.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task {
            await state.addManualNodes(nodes)
            isSubmitting = false
            if let message = state.errorMessage {
                localError = message
                state.dismissError()
            } else {
                dismiss()
            }
        }
    }

    // MARK: - 手动填写（Hysteria2）

    private var manualForm: some View {
            CardForm {
                CardSection("基本信息") {
                    LabeledContent("名称") { TextField("名称", text: $name).labelsHidden().inputField().frame(maxWidth: 260) }
                    LabeledContent("服务器") { TextField("服务器", text: $server).labelsHidden().inputField().frame(maxWidth: 260) }
                    LabeledContent("端口") { TextField("端口", text: $port).labelsHidden().inputField().frame(maxWidth: 260) }
                    LabeledContent("密码") { SecureField("密码", text: $password).labelsHidden().inputField().frame(maxWidth: 260) }
                }
                CardSection("TLS") {
                    LabeledContent("SNI") { TextField("SNI（可选）", text: $sni, prompt: Text("可选")).labelsHidden().inputField().frame(maxWidth: 260) }
                    Toggle("跳过证书验证", isOn: $skipCertificateVerification)
                }
                CardSection("可选参数") {
                    LabeledContent("Obfs 密码") { TextField("Obfs 密码（salamander，可选）", text: $obfsPassword, prompt: Text("salamander，可选")).labelsHidden().inputField().frame(maxWidth: 260) }
                    LabeledContent("上行 Mbps") { TextField("上行 Mbps（可选）", text: $uploadMbps, prompt: Text("可选")).labelsHidden().inputField().frame(maxWidth: 260) }
                    LabeledContent("下行 Mbps") { TextField("下行 Mbps（可选）", text: $downloadMbps, prompt: Text("可选")).labelsHidden().inputField().frame(maxWidth: 260) }
                }
                if let localError {
                    CardSection {
                        Label(localError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
    }

    private func addNode() {
        guard let portValue = Int(port),
              let uploadValue = optionalInt(uploadMbps),
              let downloadValue = optionalInt(downloadMbps) else {
            localError = "端口和带宽必须是整数"
            return
        }
        let form = ManualHysteria2(
            name: name,
            server: server,
            port: portValue,
            password: password,
            sni: sni,
            skipCertificateVerification: skipCertificateVerification,
            obfsPassword: obfsPassword.isEmpty ? nil : obfsPassword,
            uploadMbps: uploadValue,
            downloadMbps: downloadValue
        )
        do {
            _ = try form.makeNode()
        } catch {
            localError = error.localizedDescription
            return
        }
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            await state.addManual(form)
            isSubmitting = false
            if let message = state.errorMessage {
                // 失败原因就地显示，不要表现成「点了没反应」。
                localError = message
                state.dismissError()
            } else {
                dismiss()
            }
        }
    }

    private func optionalInt(_ value: String) -> Int?? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .some(nil) : Int(trimmed).map(Optional.some)
    }
}
