import Foundation

/// 菜单栏图标样式。放在 Core 里是为了能进 `settings.json`。
///
/// 三种都保留而不是选一个：菜单栏图标是用户每天看几十次的东西，
/// 而"哪个更好认"高度依赖个人的菜单栏有多挤、深浅色偏好、以及旁边都是什么图标。
public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 双峰山脊线稿。与 App 图标同源，最轻。
    case peak
    /// 山谷 + 通道。轮廓起伏最大，挤在一堆图标里也容易挑出来。
    case valley
    /// 盾形 + 峰。强调"防护"，与常见 VPN 客户端的视觉惯例一致。
    case shield

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .peak: "山脊"
        case .valley: "山谷"
        case .shield: "盾峰"
        }
    }

    public var summary: String {
        switch self {
        case .peak: "与 App 图标同源的双峰线稿，最轻"
        case .valley: "起伏最大，菜单栏拥挤时最好认"
        case .shield: "盾形外框，强调防护"
        }
    }
}
