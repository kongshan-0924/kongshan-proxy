import SwiftUI

/// 「连接」页：本机 / 局域网两个分段。
///
/// 2026-09-17 把原「共享」页并进来。共享页的「已接入的设备」与连接表回答同一个问题——
/// **此刻谁在用我的网络**；一个是本机进程，一个是局域网设备。
/// 共享页原本只有四个小分区，其中「端口 / 来源白名单」是几个月一次的配置，已搬进设置→接管。
///
/// 容器只持有分段状态；搜索与操作在子视图的页内顶栏（PageTopBar）。
struct ConnectionsPageView: View {
    enum Tab: String, CaseIterable {
        case local = "本机"
        case lan = "局域网"
    }

    @State private var tab: Tab = .local

    var body: some View {
        ConnectionsView(scope: $tab)
    }
}
