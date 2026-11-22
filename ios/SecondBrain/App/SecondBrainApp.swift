import SecondBrainKit
import SwiftUI

@main
struct SecondBrainApp: App {
    @State private var app = AppModel()
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var phase

    init() {
        Notifier.shared.setUp()
    }

    /// Settings → Appearance: follow iOS, or always light / always dark.
    private var scheme: ColorScheme? {
        if ProcessInfo.processInfo.arguments.contains("-SecondBrainDark") { return .dark }
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(.blue)
                .preferredColorScheme(scheme)
                .onOpenURL { app.open(link: $0.absoluteString) }
                .task {
                    Notifier.shared.onOpen = { [app] link in app.open(link: link) }
                }
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .active:
                app.changed()
                app.startLive()
                Task { await Notifier.shared.poll() }
            case .background:
                app.stopLive()
                Notifier.shared.schedule()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.isConnected {
                MainTabs()
            } else {
                ConnectView()
            }
        }
        .overlay(alignment: .top) { ToastView() }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: app.path(.home)) {
                    HomeView().withRoutes()
                }
            }
            Tab("People", systemImage: "person.2", value: AppTab.people) {
                NavigationStack(path: app.path(.people)) {
                    PeopleView().withRoutes()
                }
            }
            Tab("Lists", systemImage: "checklist", value: AppTab.lists) {
                NavigationStack(path: app.path(.lists)) {
                    ListsView().withRoutes()
                }
            }
            Tab("Review", systemImage: "checkmark.circle", value: AppTab.review) {
                NavigationStack(path: app.path(.review)) {
                    ReviewView().withRoutes()
                }
            }
            .badge(app.info?.reviewCount ?? 0)
            Tab("More", systemImage: "ellipsis", value: AppTab.more) {
                NavigationStack(path: app.path(.more)) {
                    MoreView().withRoutes()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            CaptureBar()
        }
        .sheet(isPresented: $app.showCapture) {
            CaptureSheet()
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: Binding(get: { app.focusItem.map(FocusID.init) },
                                       set: { app.focusItem = $0?.id })) { f in
            FocusView(itemId: f.id)
        }
    }
}

struct FocusID: Identifiable {
    let id: String
}

extension View {
    /// Every tab can push every screen.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .event(let id): EventView(eventId: id)
            case .person(let key): PersonView(key: key)
            case .today: TodayView()
            case .weekly: WeeklyView()
            case .activity(let status): ActivityView(initialStatus: status)
            case .status: StatusView()
            case .settings: SettingsView()
            case .server: ServerView()
            }
        }
    }
}
