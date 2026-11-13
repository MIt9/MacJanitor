import SwiftUI

@main
struct MacJanitorApp: App {
    @AppStorage("language") private var language = "en"
    var body: some Scene {
        WindowGroup("MacJanitor") {
            TabView {
                ProcessesView()
                    .tabItem { Label("Процеси", systemImage: "cpu") }
                PortsView()
                    .tabItem { Label("Порти", systemImage: "network") }
                StorageView()
                    .tabItem { Label("Сховище", systemImage: "internaldrive") }
            }
            .frame(minWidth: 900, minHeight: 600)
            .environment(\.locale, Locale(identifier: language))
        }
        .commands {
            CommandMenu("Language / Мова") {
                Button("English") { language = "en" }
                Button("Українська") { language = "uk" }
            }
        }
        Settings {
            AISettingsView().environment(\.locale, Locale(identifier: language))
        }
    }
}
