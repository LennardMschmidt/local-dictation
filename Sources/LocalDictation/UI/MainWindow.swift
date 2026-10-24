import AppKit
import SwiftUI

/// The app window: sidebar on the left, the selected page in a rounded panel on the right,
/// and a small toolbar for appearance and notifications.
final class MainWindowController {
    /// The smallest content area of the main window: the settings over it stay readable.
    static let minimumContent = NSSize(width: 1000, height: 652)

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(section: AppModel.Section? = nil) {
        if section == .settings {
            model.openSettings()
        } else if let section {
            model.section = section
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "LocalDictation"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // Below this the settings, which lie over the window, squeeze their rows into single
            // letters; Wispr Flow stops resizing at a similar size. The hosting view replaces the
            // window's minimum with that of its SwiftUI content after the first layout, so the
            // minimum is set on the content (MainView) as well; this one covers the restore below.
            window.minSize = NSSize(width: 1000, height: 680)
            window.setFrameAutosaveName("LocalDictationMain")
            // A frame saved before the minimum existed is enlarged to it.
            if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
                window.setContentSize(NSSize(width: max(window.frame.width, window.minSize.width),
                                             height: max(window.frame.height, window.minSize.height)))
            }
            window.contentView = NSHostingView(rootView: MainView(model: model)
                .frame(minWidth: Self.minimumContent.width, minHeight: Self.minimumContent.height))
            window.center()
            self.window = window
        }
        model.reloadHistory()
        model.refreshSystemState()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    /// The sidebar folded to its icons, like Wispr Flow's; remembered across launches.
    @AppStorage("sidebarCollapsed") private var collapsed = false
    /// In full screen the window buttons are gone, so the sidebar button moves to the edge.
    @State private var fullScreen = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, collapsed: collapsed)
                .frame(width: collapsed ? 64 : 190)
                .layoutPriority(1)
            VStack(spacing: 0) {
                TopBar(model: model)
                    .frame(height: 39)
                // minWidth 0: a page that would like to be wider is cut off instead of pushing the
                // sidebar out of the window.
                page
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.trailing, 9)
                    .padding(.bottom, 9)
            }
        }
        .overlay(alignment: .topLeading) {
            // Next to the window buttons, in the same place whether the sidebar is open or not.
            SidebarToggle(collapsed: $collapsed)
                .padding(.leading, fullScreen ? 17 : 86)
                .padding(.top, 8)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in fullScreen = false }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: collapsed)
        .overlay {
            if model.showingSettings {
                SettingsOverlay(model: model).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.showingSettings)
        // Switches and selections in Wispr Flow's near-black instead of the system blue.
        .tint(Theme.text)
        .foregroundStyle(Theme.text)
        .background(Theme.window)
        .ignoresSafeArea()
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .home: HomeView(model: model)
        case .notetaker: NotetakerView(model: model)
        case .insights: InsightsView(model: model)
        case .dictionary: DictionaryView(model: model)
        case .snippets: SnippetsView(model: model)
        case .style: StyleView(model: model)
        case .transforms: TransformsView(model: model)
        case .scratchpad: ScratchpadView(model: model)
        case .settings: HomeView(model: model)
        case .help: HelpView(model: model)
        }
    }
}

/// Logo at the top below the window buttons, the sections in a scroll area, settings and help at the bottom. Only the middle scrolls, so a low window never
/// pushes the logo into the window buttons.
private struct Sidebar: View {
    @ObservedObject var model: AppModel
    let collapsed: Bool

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: collapsed ? 20 : 17, weight: .bold))
                if !collapsed {
                    Text("LocalDictation")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.opacity)
                }
            }
            .padding(.leading, collapsed ? 0 : 10)
            .padding(.top, 44)
            .padding(.bottom, collapsed ? 20 : 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: collapsed ? .center : .leading, spacing: collapsed ? 6 : 2) {
                    ForEach(AppModel.Section.main) { section in
                        SidebarItem(section: section, selected: model.section == section, badge: nil, collapsed: collapsed) {
                            model.section = section
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            }

            Divider().padding(.horizontal, 8).padding(.vertical, 6)
            SidebarItem(section: .settings, selected: model.showingSettings, badge: nil, collapsed: collapsed) { model.openSettings() }
            SidebarItem(section: .help, selected: model.section == .help, badge: nil, collapsed: collapsed) { model.section = .help }
                .padding(.bottom, 10)
        }
        .padding(.horizontal, collapsed ? 6 : 9)
    }
}

/// The button that folds the sidebar to its icons and back.
private struct SidebarToggle: View {
    @Binding var collapsed: Bool
    @State private var hovering = false

    var body: some View {
        Button { collapsed.toggle() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .regular))
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.selection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? "Show sidebar" : "Hide sidebar")
    }
}

private struct SidebarItem: View {
    let section: AppModel.Section
    let selected: Bool
    let badge: String?
    var collapsed = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if collapsed {
            Button(action: action) {
                Image(systemName: section.icon)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(section.title)
        } else {
            row
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.orange.opacity(0.85)))
                        .foregroundStyle(Color.black.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 33)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Appearance menu and notifications, top right like in Wispr Flow.
private struct TopBar: View {
    @ObservedObject var model: AppModel
    @State private var showingEvents = false

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            Menu {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        model.appearanceMode = mode
                    } label: {
                        if model.appearanceMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Label(mode.title, systemImage: mode.icon)
                        }
                    }
                }
            } label: {
                Image(systemName: model.appearanceMode == .dark ? "moon.fill" : "moon")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Appearance")

            Button {
                showingEvents.toggle()
                model.unreadEvents = 0
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .overlay(alignment: .topTrailing) {
                        if model.unreadEvents > 0 {
                            Circle().fill(Theme.orange).frame(width: 6, height: 6).offset(x: -6, y: 6)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Notifications")
            .popover(isPresented: $showingEvents, arrowEdge: .bottom) {
                EventsList(events: model.events)
            }
        }
        .padding(.trailing, 16)
    }
}

private struct EventsList: View {
    let events: [AppModel.Event]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications").font(.headline).padding(10)
            Divider()
            if events.isEmpty {
                Text("Nothing new.").foregroundStyle(.secondary).padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.title).font(.callout.weight(.semibold))
                                    Spacer()
                                    Text(event.date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(event.detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 240)
            }
        }
        .frame(width: 240)
    }
}
