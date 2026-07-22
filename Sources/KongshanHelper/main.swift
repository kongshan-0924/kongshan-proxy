import Foundation
import HelperProtocol

// kongshan 特权助手（以 root 由 launchd 运行）。职责单一：起/停内置 sing-box TUN 内核。
//
// ⚠️ 安全关键组件。设计与威胁模型见 docs/design/tun-passwordless-helper.md。
// 本文件目前是**骨架**：结构就位、但不做任何特权操作（默认拒绝）。真正的
//   ① Unix socket 服务循环、② 对端 SecCode 审计校验、③ 只读 FD 收配置、④ 固定 exec 内置 sing-box
// 在下一里程碑连同独立安全审查一起落地。骨架保持"拒绝优先"，即使被误运行也不会提权。

let helperVersion = "0.0.1-skeleton"

/// 对端身份校验。**拒绝优先**：真正实现(SecCode + audit token + 信任配置)落地前一律返回 false，
/// 确保骨架状态下不会为任何调用方执行特权动作。
enum HelperSecurity {
    static func isTrustedClient(auditToken: Data, trust: HelperTrustConfig) -> Bool {
        // TODO(里程碑2 + 安全审查): SecCodeCreateWithAuditToken → SecCodeCheckValidityWithErrors，
        //   校验 有效签名 + identifier==clientSigningIdentifier + 可执行路径==trust.clientExecutablePath
        //   (+ 可选 cdhash)。在此之前拒绝一切。
        false
    }

    /// 读取安装时 root 写入的信任配置(0600)。缺失/损坏 → nil（随后一律拒绝）。
    static func loadTrustConfig() -> HelperTrustConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: HelperConstants.trustConfigPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(HelperTrustConfig.self, from: data)
    }
}

/// 处理已鉴权连接上的一个请求。特权动作(起/停内核)骨架期返回未实现。
enum HelperEngine {
    static func handle(_ request: HelperRequest, configFD: Int32?) -> HelperResponse {
        switch request {
        case .status:
            return HelperResponse(ok: true, message: "helper alive (skeleton)", helperVersion: helperVersion)
        case .startTun, .stopTun:
            // TODO(里程碑2): 只读 FD 喂给内置 sing-box stdin / 停自起进程。骨架期不执行。
            return HelperResponse(ok: false, message: "not implemented in skeleton", helperVersion: helperVersion)
        }
    }
}

// 骨架期：不监听 socket、不做特权操作，仅表明构建/打包链路通。socket 服务循环随下一里程碑落地。
FileHandle.standardError.write(Data("kongshan-helper \(helperVersion): skeleton, no privileged action.\n".utf8))
exit(0)
