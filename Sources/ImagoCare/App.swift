import SwiftUI
import AppKit

@main
struct ImagoCareApp: App {
    @StateObject private var state = AppState()
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var phone = PhoneHub()

    var body: some Scene {
        WindowGroup("Limpo e Voando", id: "main") {
            ContentView()
                .environmentObject(state)
                .environmentObject(monitor)
                .environmentObject(phone)
                .onAppear {
                    AppearanceMode.current.apply()
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra {
            MenuBarView().environmentObject(state).environmentObject(monitor)
        } label: {
            MenuBarIcon().environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            ZStack {
                switch state.section {
                case .home: HomeView()
                case .cleanup: CleanupView()
                case .performance: PerformanceView()
                case .apps: AppsView()
                case .clutter: ClutterView()
                case .lens: SpaceLensView()
                case .cloud: CloudView()
                case .compress: CompressView()
                case .download: DownloadView()
                case .routines: RoutinesView()
                case .organize: OrganizerView()
                case .phone: PhoneView()
                case .backup: BackupView()
                case .tools: ToolsView()
                case .activity: ActivityView()
                }
            }
            .id(state.section)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            .padding(.leading, 12).padding(.trailing, 36).padding(.top, 30).padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Backdrop(section: state.section))
        .overlay(alignment: .top) { Toast() }
        .overlay(alignment: .bottom) { ReceiptBanner() }
        .tint(Theme.blue)
        .frame(minWidth: 1060, minHeight: 720)
    }
}

/// Tela de abertura de cada módulo: ícone de vidro, título, recursos e "Analisar".
struct ModuleIntro: View {
    let section: Section
    var buttonTitle = "Analisar"
    var action: (() -> Void)? = nil
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 70) {
                GlassHero(symbol: section.heroSymbol, tint: section.accent, radius: section.heroRadius, size: 290,
                          animated: state.busy == nil)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(section.number).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        Rectangle().fill(Color.ink.opacity(0.4)).frame(width: 22, height: 0.8)
                        Text(section.title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(2.2)
                    }
                    .foregroundStyle(Color.ink.opacity(0.76))
                    .padding(.bottom, 12)
                    Text(section.title)
                        .font(.system(size: 50, weight: .thin))
                        .tracking(-0.5)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(section.pitch)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.ink.opacity(0.74))
                        .frame(maxWidth: 420, alignment: .leading)
                        .padding(.top, 14)
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(section.features, id: \.0) { f in
                            HStack(spacing: 14) {
                                IconTile(symbol: f.1)
                                Text(f.0).font(.system(size: 16, weight: .regular)).foregroundStyle(Color.ink.opacity(0.88))
                            }
                        }
                    }
                    .padding(.top, 34)
                }
                .frame(minWidth: 380, alignment: .leading)
            }
            Spacer()
            VStack(spacing: 14) {
                if state.busy == section {
                    LiveScanProgress(meter: state.meter, phase: state.phase)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                RoundAction(title: buttonTitle, tint: section.accent, busy: state.busy == section,
                            enabled: state.busy == nil || state.busy == section) {
                    if let action { action() } else { Task { await state.scan(section) } }
                }
                .keyboardShortcut(.defaultAction)
                Text("ou aperte ↩︎").font(.system(size: 10.5)).foregroundStyle(Color.ink.opacity(0.74))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Toast: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let msg = state.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(state.section.accent)
                Text(msg).font(.system(size: 13, weight: .medium))
                Button { state.toast = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .liquidGlass(in: Capsule())
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: msg) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                withAnimation { if state.toast == msg { state.toast = nil } }
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Limpo e Voando").font(.headline)
            if monitor.diskLow {
                Label("Disco quase cheio: \(FS.fmt(monitor.diskFree)) livres. Exportar e gravar pode falhar.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.routinesFreedThisWeek > 0 {
                Label("Rotinas liberaram \(FS.fmt(state.routinesFreedThisWeek)) esta semana", systemImage: "clock.arrow.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if monitor.pressure >= 2 {
                Label("Memória sob pressão: feche apps pesados.", systemImage: "memorychip")
                    .font(.caption).foregroundStyle(.orange)
            }
            Ring(value: monitor.cpu, label: "CPU", detail: "\(Int(monitor.cpu * 100))% em uso", tint: Theme.warm)
            Ring(value: monitor.memFraction, label: "MEMÓRIA",
                 detail: "\(FS.fmt(Int64(monitor.memUsed))) de \(FS.fmt(Int64(monitor.memTotal)))", tint: Theme.purple)
            Ring(value: monitor.diskUsedFraction, label: "DISCO",
                 detail: "\(FS.fmt(monitor.diskFree)) livres", tint: Theme.blue)
            Divider()
            HStack {
                Button("Abrir Limpo e Voando") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) { w.makeKeyAndOrderFront(nil) }
                    else { openWindow(id: "main") }
                }
                Spacer()
                Button("Sair") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Ícone da barra de menus: vira alerta quando o disco está quase cheio.
struct MenuBarIcon: View {
    @EnvironmentObject var monitor: SystemMonitor
    var body: some View {
        if monitor.diskLow {
            Label("\(Int(Double(monitor.diskFree) / 1_000_000_000)) GB", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "sparkles")
        }
    }
}

/// Barra fina de progresso com porcentagem — aparece ao apertar "Analisar".
/// Barra que observa só o medidor (leve: não invalida o resto da tela).
struct LiveScanProgress: View {
    @ObservedObject var meter: ScanMeter
    let phase: String
    var body: some View { ScanProgress(value: meter.value, phase: phase) }
}

struct ScanProgress: View {
    let value: Double
    let phase: String

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(phase)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink.opacity(0.74))
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text("\(Int((min(max(value, 0), 1) * 100).rounded()))%")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ink.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.blue.opacity(0.75), Theme.blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * min(max(value, 0), 1)))
                        .shadow(color: Theme.blue.opacity(0.55), radius: 5)
                        .animation(.easeOut(duration: 0.25), value: value)
                }
            }
            .frame(height: 3)
        }
        .frame(width: 340)
        .animation(.easeOut(duration: 0.2), value: Int(value * 100))
    }
}
