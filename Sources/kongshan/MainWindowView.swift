import SwiftUI

struct MainWindowView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                Label("节点", systemImage: "point.3.connected.trianglepath.dotted")
                Label("设置", systemImage: "gearshape")
            }
            .navigationTitle("kongshan")
        } detail: {
            ContentUnavailableView(
                "代理尚未启动",
                systemImage: "shield.slash",
                description: Text("添加订阅或手动节点后即可开始使用。")
            )
        }
    }
}
