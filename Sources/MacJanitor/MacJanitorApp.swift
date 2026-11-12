import SwiftUI

@main
struct MacJanitorApp: App {
    var body: some Scene {
        WindowGroup("MacJanitor") {
            TabView {
                ProcessesView()
                    .tabItem { Label("Процеси", systemImage: "cpu") }
                StorageView()
                    .tabItem { Label("Сховище", systemImage: "internaldrive") }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
    }
}
