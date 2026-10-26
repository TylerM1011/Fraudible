import SwiftUI

@main
struct FraudibleApp: App {
    @State private var library: Library
    @State private var player: AudiobookPlayer
    @State private var kokoro: KokoroManager
    @State private var offlineAudio: OfflineAudioMaker
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _player = State(initialValue: AudiobookPlayer(library: library))
        let kokoro = KokoroManager()
        _kokoro = State(initialValue: kokoro)
        _offlineAudio = State(initialValue: OfflineAudioMaker(library: library, kokoro: kokoro))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(player)
                .environment(kokoro)
                .environment(offlineAudio)
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
    enum Tab: Hashable { case library, search }
    enum Route: Hashable { case reader(String) }

    var tab: Tab = .library
    var searchPath: [Route] = []
    var libraryPath: [Route] = []
    var showPlayer = false

    func openReader(_ bookID: String) {
        switch tab {
        case .search: searchPath.append(.reader(bookID))
        case .library: libraryPath.append(.reader(bookID))
        }
    }

    /// Open a ready book the right way: the Now Playing sheet for audiobooks, the reader for ebooks.
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
    @Environment(AppRouter.self) private var router
    @Environment(AudiobookPlayer.self) private var player

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.tab) {
            Tab("Library", systemImage: "books.vertical.fill", value: AppRouter.Tab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .navigationDestination(for: AppRouter.Route.self, destination: destination)
                }
            }
            // The search tab sits apart in the tab bar, with the search field built in.
            Tab(value: AppRouter.Tab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppRouter.Route.self, destination: destination)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(MiniPlayerAccessory(enabled: player.book != nil))
        .sheet(isPresented: $router.showPlayer) {
            ListenView()
        }
    }

    @ViewBuilder
    private func destination(_ route: AppRouter.Route) -> some View {
        switch route {
        case .reader(let id): ReaderView(bookID: id)
        }
    }
}

/// The mini player sits in the tab bar's accessory slot, like Apple Music.
/// iOS 26.1 can hide the slot when nothing is loaded; on 26.0 it shows "Not playing".
private struct MiniPlayerAccessory: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) { MiniPlayer() }
        } else {
            content.tabViewBottomAccessory { MiniPlayer() }
        }
    }
}
