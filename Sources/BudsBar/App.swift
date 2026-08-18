import SwiftUI

@main
struct BudsBarApp: App {
    @State private var buds = Buds()

    init() {
        #if DEBUG
        BudsProtocol.selfCheck()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(buds: buds)
        } label: {
            Image(systemName: buds.isConnected ? "airpods.pro" : "airpods.pro.chargingcase.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
