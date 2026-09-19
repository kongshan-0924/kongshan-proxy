import SwiftUI

/// 「连接」页：本机 / 局域网两个分段。
///
/// 2026-09-17 把原「共享」页并进来。共享页的「已接入的设备」与连接表回答同一个问题——
/// **此刻谁在用我的网络**；一个是本机进程，一个是局域网设备。
/// 共享页原本只有四个小分区，其中「端口 / 来源白名单」是几个月一次的配置，已搬进设置→接管。
///
/// 容器只提供 `.principal` 分段与 `.navigationTitle`；副标题、搜索与其余工具栏项由子视图声明。
struct ConnectionsPageView: View {
    enum Tab: String, CaseIterable {
        case local = "本机"
        case lan = "局域网"
    }

    @State private var tab: Tab = .local

    var body: some View {
        // 结构化 if：连接页与共享页各自有 onAppear/onDisappear 启停的监控，
        // 常驻会让两条订阅同时跑。
        Group {
            switch tab {
            case .local: ConnectionsView()
            case .lan: SharingView()
            }
        }
        .navigationTitle("连接")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("连接来源", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}
