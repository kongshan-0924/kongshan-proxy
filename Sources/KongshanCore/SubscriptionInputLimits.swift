import Foundation

/// 订阅输入的硬上限。
///
/// 订阅是**外部不可信输入**：内容由机场面板给出，用户只提供一个 URL。
/// 2026-09-17 审计实测了三条放大路径，这里逐条封顶。
public enum SubscriptionInputLimits {
    /// 单份订阅文档的体积上限。真实机场订阅（数百节点 + 数千规则）约 100–500 KB，
    /// 8 MB 已经宽出一个数量级。
    public static let documentByteLimit = 8 * 1_048_576

    /// YAML 别名引用总数上限。
    ///
    /// **为什么需要**：`Yams.load` 把每一处 `*anchor` 展开成独立对象图。
    /// 审计探针实测：8 路扇出嵌套 6 层（48 处引用、290 字节）→ 210 万个元素 / 0.74 秒；
    /// 每多一层 ×8，嵌套 8 层就是 1.3 亿个元素，内存直接爆掉。
    ///
    /// **为什么是 24**：N 处引用散在 k 个锚点时，展开规模约 (N/k)^k，在 k≈N/e 时最大。
    /// N=24 的最坏情形约 10^4 量级，可控；N=48 就到 10^7，不可控。
    /// 真实机场订阅**一处别名都不用**，这个额度只是为了不误伤边缘写法。
    public static let aliasReferenceLimit = 24

    /// 转换后的节点数上限。见过最大的机场约 300 个节点。
    public static let nodeLimit = 2_000
    /// 转换后的分流规则数上限。规则集通常几千条。
    /// **只管订阅 `rules:` 里的单条规则**；规则集内容另有上限（下面几项）。
    public static let ruleLimit = 50_000

    /// 单份规则集下载的体积上限。实测真实订阅里最大的一份（广告拦截，约 3.9 万条）Clash 格式约 1 MB。
    public static let ruleSetByteLimit = 16 * 1_048_576
    /// 单份规则集的条目上限。实测最大 3.9 万条，放宽一个数量级。
    public static let ruleSetEntryLimit = 500_000
    /// 一份订阅引用的规则集个数上限。实测 16 个。
    public static let ruleSetCountLimit = 128
    /// 一份订阅全部规则集的条目总数上限。实测合计约 7.8 万条。
    public static let ruleSetTotalEntryLimit = 2_000_000

    /// 解析前的输入校验。
    public static func validate(yaml: String) throws {
        let bytes = yaml.utf8.count
        guard bytes <= documentByteLimit else {
            throw SubscriptionConversionError.documentTooLarge(bytes: bytes, limit: documentByteLimit)
        }
        let aliases = aliasReferenceCount(in: yaml)
        guard aliases <= aliasReferenceLimit else {
            throw SubscriptionConversionError.tooManyAliasReferences(
                count: aliases, limit: aliasReferenceLimit
            )
        }
    }

    /// 统计文档里的 YAML 别名引用数。
    ///
    /// **先找锚点定义再数引用**，不是直接数 `*`：Clash 规则里 `*.google.com` 这种通配域名
    /// 到处都是，按 `*` 裸数会把正常订阅全部误杀。YAML 要求别名的锚点先定义
    /// （`&name` 在前、`*name` 在后），所以没有任何 `&` 定义时引用数必然为 0——
    /// 真实订阅走的正是这条零开销分支。
    public static func aliasReferenceCount(in yaml: String) -> Int {
        let anchors = anchorNames(in: yaml)
        guard !anchors.isEmpty else { return 0 }
        var total = 0
        let scalars = Array(yaml.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "*" else {
                index += 1
                continue
            }
            var end = index + 1
            while end < scalars.count, isAnchorCharacter(scalars[end]) { end += 1 }
            let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
            if !name.isEmpty, anchors.contains(name) { total += 1 }
            index = max(end, index + 1)
        }
        return total
    }

    /// 文档里定义过的锚点名（`&name`）。
    public static func anchorNames(in yaml: String) -> Set<String> {
        var names: Set<String> = []
        let scalars = Array(yaml.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                index += 1
                continue
            }
            var end = index + 1
            while end < scalars.count, isAnchorCharacter(scalars[end]) { end += 1 }
            let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
            if !name.isEmpty { names.insert(name) }
            index = max(end, index + 1)
        }
        return names
    }

    /// YAML 锚点名允许的字符（保守取值：字母数字与 `-` `_`）。
    private static func isAnchorCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
    }
}
