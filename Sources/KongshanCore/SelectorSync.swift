import Foundation

/// 把内核里各 selector 的选中项对齐到 App 的选择。App 是唯一的真相来源。
///
/// **为什么需要**：TUN 模式开了 `cache_file`（跨重启保留 Fake-IP 映射），而 sing-box 的 selector
/// 启动时**优先恢复缓存里上次的选择、忽略配置里的 `default`**（1.13.21 实测复现）。App 把用户的选择
/// 写进 `default`，于是系统代理模式下改的选择（那时没有缓存）一到 TUN 就被旧缓存盖掉——界面显示 A，
/// 流量走 B。2026-09-19 真机：界面显示节点 A，内核实际在用早已不通的节点 B，
/// TUN 下所有走代理的连接全部超时，连订阅与规则集也更新不了。
///
/// 所以每次内核（重）启动通过健康检查后，都按 App 的选择逐组下发，并**回读核对**。
public enum SelectorSync {
    public struct Correction: Equatable, Sendable {
        /// 内核原先选中的成员（通常是缓存恢复出来的旧选择）。
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// 被改回来的组。
        public var corrected: [String: Correction] = [:]
        /// 目标不在可选成员里、下发失败、或回读仍不一致的组（按名排序）。
        public var failed: [String] = []

        public init(corrected: [String: Correction] = [:], failed: [String] = []) {
            self.corrected = corrected
            self.failed = failed
        }
    }

    /// 配置里每个 selector 的 `default`——即生成配置那一刻 App 的选择。
    public static func intendedSelections(inConfig config: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for outbound in outbounds where outbound["type"] as? String == "selector" {
            guard let tag = outbound["tag"] as? String,
                  let target = outbound["default"] as? String else { continue }
            result[tag] = target
        }
        return result
    }

    /// 逐组对齐。内核里没有的组跳过（配置变了、组已不存在）；读不到内核状态时抛错。
    public static func align(_ client: ClashAPIClient, to intended: [String: String]) async throws -> Outcome {
        let states = try await client.selectorStates()
        var outcome = Outcome()
        for (group, target) in intended.sorted(by: { $0.key < $1.key }) {
            guard let state = states[group], state.now != target else { continue }
            guard state.all.contains(target) else {
                outcome.failed.append(group)
                continue
            }
            do {
                try await client.select(node: target, in: group)
                outcome.corrected[group] = Correction(from: state.now, to: target)
            } catch {
                outcome.failed.append(group)
            }
        }
        if !outcome.corrected.isEmpty {
            // 回读核对：下发成功不等于生效，以内核报告的当前值为准。
            let after = try await client.selectorStates()
            for (group, correction) in outcome.corrected where after[group]?.now != correction.to {
                outcome.corrected[group] = nil
                outcome.failed.append(group)
            }
        }
        outcome.failed.sort()
        return outcome
    }
}
