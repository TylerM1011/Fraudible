import SwiftUI

@main
struct FraudibleApp: App {
    @State private var library: Library
    @State private var player: AudiobookPlayer
    @State private var kokoro = KokoroManager()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _player = State(initialValue: AudiobookPlayer(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(player)
                .environment(kokoro)
                .environment(router)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.saveNow() }
        }
    }
}

/// Where the app is: the selected tab, each tab's navigation stack, and the player sheet.
@Observable
final class AppRouter {
    enum Tab: Hashable { case search, library }
    enum Route: Hashable { case reader(String) }

    var tab: Tab = .search
    var searchPath: [Route] = []
    var libraryPath: [Route] = []
    var showPlayer = false

    func openReader(_ bookID: String) {
        switch tab {
        case .search: searchPath.append(.reader(bookID))
        case .library: libraryPath.append(.reader(bookID))
        }
    }

    /// Open a ready book the right way: the player sheet for audiobooks, the reader for ebooks.
    func open(_ book: LibraryBook, player: AudiobookPlayer) {
        guard book.isReady else { return }
        switch book.kind {
        case .audiobook:
            player.open(book)
            showPlayer = true
        case .tts:
            openReader(book.id)
        }
    }
}

struct RootView: View {
    @AppStorage("fraudible.themeMode") private var mode = ThemeMode.system.rawValue
    @Environment(\.colorScheme) private var systemScheme
    @Environment(AppRouter.self) private var router

    private var scheme: ColorScheme {
        switch ThemeMode(rawValue: mode) ?? .system {
        case .light: .light
        case .dark: .dark
        case .system: systemScheme
        }
    }

    var body: some View {
        @Bindable var router = router
        let c = Palette.forScheme(scheme)

        TabView(selection: $router.tab) {
            Tab("Search", systemImage: "magnifyingglass", value: AppRouter.Tab.search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppRouter.Route.self, destination: destination)
                }
            }
            Tab("Library", systemImage: "books.vertical", value: AppRouter.Tab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .navigationDestination(for: AppRouter.Route.self, destination: destination)
                }
            }
        }
        .tint(c.accent)
        .sheet(isPresented: $router.showPlayer) {
            ListenView()
                .environment(\.palette, c)
                .preferredColorScheme(mode == ThemeMode.system.rawValue ? nil : scheme)
        }
        .environment(\.palette, c)
        .preferredColorScheme(mode == ThemeMode.system.rawValue ? nil : scheme)
    }

    @ViewBuilder
    private func destination(_ route: AppRouter.Route) -> some View {
        switch route {
        case .reader(let id): ReaderView(bookID: id)
        }
    }
}
