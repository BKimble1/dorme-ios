import SwiftUI
import DORMEKit

@main
struct DORMEApp: App {
    @State private var store = RobotStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            Group {
                switch store.tab {
                case .home: HomeView()
                case .control: ControlView()
                case .tasks: TasksView()
                case .robot: RobotView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 10) {
                if let toast = store.toast {
                    ToastView(toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                CapsuleTabBar(selection: $store.tab)
            }
            .padding(.bottom, 8)
            .animation(.spring(duration: 0.3), value: store.toast)
        }
        .tint(Theme.ink)
        .preferredColorScheme(.light)
        .sheet(isPresented: $store.showConnect) { ConnectView() }
        .sheet(isPresented: $store.showDemoControls) { DemoControlsView().presentationDetents([.medium, .large]) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.backgrounded() }
        }
        .onAppear {
            if !store.hasClient { store.showConnect = true }
        }
    }
}

struct ToastView: View {
    var toast: RobotStore.Toast
    var body: some View {
        HStack(spacing: 10) {
            StatusDot(level: toast.level)
            Text(toast.text).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
