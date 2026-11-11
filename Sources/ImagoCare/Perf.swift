import SwiftUI
import AppKit
import Darwin

// MARK: - Apps pesados, memória virtual e pressão de memória

struct HeavyApp: Identifiable, Sendable {
    var id: String { path }
    let path: String          // caminho do .app
    let name: String
    let memory: Int64         // RAM somada de todos os processos do app
    let cpu: Double           // % de CPU somado
    let processes: Int
}

enum Perf {
    /// Agrupa todos os processos por app (Chrome + "Chrome Helper" contam juntos).
    static func heavyApps() -> [HeavyApp] {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "rss=,%cpu=,comm="]
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        var mem: [String: Int64] = [:], cpu: [String: Double] = [:], count: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let rss = Int64(parts[0]), let c = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { continue }
            let comm = String(parts[2])
            // primeiro ".app" do caminho = o app dono do processo
            guard let r = comm.range(of: ".app/") else { continue }
            let app = String(comm[..<r.lowerBound]) + ".app"
            if app.hasPrefix("/System/") { continue }
            mem[app, default: 0] += rss * 1024
            cpu[app, default: 0] += c
            count[app, default: 0] += 1
        }
        let own = Bundle.main.bundlePath
        return mem.keys.filter { $0 != own }.map {
            HeavyApp(path: $0, name: (($0 as NSString).lastPathComponent as NSString).deletingPathExtension,
                     memory: mem[$0] ?? 0, cpu: cpu[$0] ?? 0, processes: count[$0] ?? 0)
        }
        .sorted { $0.memory > $1.memory }
    }

    static func swapUsed() -> Int64 {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return 0 }
        return Int64(xsw.xsu_used)
    }

    /// 1 = normal, 2 = atenção, 4 = crítica
    static func pressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return Int(level)
    }

    /// Fecha o app educadamente (como ⌘Q). Retorna false se não estava aberto.
    @MainActor
    static func quit(_ app: HeavyApp) -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.path }
        running.forEach { $0.terminate() }
        return !running.isEmpty
    }
}

// MARK: - Tela de Desempenho

struct PerformanceView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @State private var pending: LaunchItem?
    @State private var heavy: [HeavyApp] = []
    @State private var showAgents = false
    @State private var prepare = false

    var body: some View {
        if state.scanned.contains(.performance) { results } else { ModuleIntro(section: .performance) }
    }

    private var pressure: (String, Color) {
        switch monitor.pressure {
        case 4: return ("Crítica", Theme.red)
        case 2: return ("Atenção", Theme.warm)
        default: return ("Normal", Theme.teal)
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TopBar(section: .performance)
                Text("Como o Mac está agora").font(.system(size: 30, weight: .light))

                // Termômetros
                HStack(spacing: 14) {
                    gauge("Pressão de memória", pressure.0, "\(FS.fmt(Int64(monitor.memUsed))) de \(FS.fmt(Int64(monitor.memTotal))) em uso",
                          monitor.memFraction, pressure.1)
                    gauge("Memória virtual (swap)", FS.fmt(monitor.swapUsed),
                          monitor.swapUsed > 4_000_000_000 ? "Alto: o Mac está usando o disco como RAM" : "Uso do disco como RAM extra",
                          min(Double(monitor.swapUsed) / 8_000_000_000, 1), monitor.swapUsed > 4_000_000_000 ? Theme.warm : Theme.teal)
                    gauge("Disco livre", FS.fmt(monitor.diskFree),
                          monitor.diskFree < 15_000_000_000 ? "Pouco espaço deixa o Mac lento" : "Espaço para trabalhar",
                          1 - monitor.diskUsedFraction, monitor.diskFree < 15_000_000_000 ? Theme.red : Theme.teal)
                    gauge("CPU", "\(Int(monitor.cpu * 100))%", "Uso do processador agora", monitor.cpu, Theme.purple)
                }

                // Apps pesados
                HStack {
                    Text("Apps pesados agora").font(.headline)
                    Spacer()
                    Text("Atualiza a cada 3 s").font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                }
                GlassCard(padding: 12) {
                    VStack(spacing: 0) {
                        if heavy.isEmpty { ProgressView().padding(20) }
                        ForEach(heavy.prefix(8)) { app in heavyRow(app); Divider().overlay(Color.ink.opacity(0.07)) }
                    }
                }

                // Tarefas
                HStack(spacing: 14) {
                    TaskCard(icon: "square.and.arrow.up.on.square.fill", title: "Preparar para exportar",
                             text: "Confere o espaço, fecha apps pesados e libera memória antes de renderizar.", button: "Preparar") {
                        prepare = true
                    }
                    TaskCard(icon: "memorychip.fill", title: "Liberar memória RAM",
                             text: "Esvazia a memória inativa. Pede sua senha de administrador.") {
                        Task { await state.runAdminTask("Liberar RAM", "/usr/sbin/purge") }
                    }
                    TaskCard(icon: "network", title: "Limpar cache de DNS",
                             text: "Ajuda quando sites não carregam ou mudaram de endereço.") {
                        Task { await state.runAdminTask("Cache DNS", "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder") }
                    }
                    TaskCard(icon: "power", title: "Itens de início",
                             text: "Escolha o que abre sozinho ao ligar o Mac.", button: "Abrir") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }

                // Agentes
                Button { withAnimation { showAgents.toggle() } } label: {
                    HStack {
                        Text("\(state.launchItems.count) agentes em segundo plano").font(.headline)
                        Image(systemName: "chevron.down").rotationEffect(.degrees(showAgents ? 180 : 0))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                if showAgents { agents }
            }
            .padding(.bottom, 20)
        }
        .task {
            while !Task.isCancelled {
                heavy = await Task.detached { Perf.heavyApps() }.value
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .sheet(isPresented: $prepare) { PrepareExportSheet(heavy: heavy) }
        .confirmationDialog("Parar e remover \(pending?.label ?? "")?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Remover", role: .destructive) {
                if let p = pending { Task { await state.removeLaunchItem(p) } }
            }
        } message: {
            Text("O agente é descarregado e o arquivo .plist vai para a Lixeira. O app dono dele pode recriá-lo.")
        }
    }

    private func gauge(_ title: String, _ value: String, _ caption: String, _ frac: Double, _ tint: Color) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.76))
                Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(tint).monospacedDigit()
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.ink.opacity(0.12))
                        Capsule().fill(tint).frame(width: max(4, g.size.width * min(max(frac, 0), 1)))
                    }
                }
                .frame(height: 6)
                Text(caption).font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.74)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heavyRow(_ app: HeavyApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.icon( app.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text("\(app.processes) processo\(app.processes == 1 ? "" : "s")").font(.caption).foregroundStyle(Color.ink.opacity(0.74))
            }
            Spacer()
            Text("\(Int(app.cpu))% CPU").font(.caption).monospacedDigit().foregroundStyle(Color.ink.opacity(0.76)).frame(width: 70, alignment: .trailing)
            Text(FS.fmt(app.memory)).monospacedDigit().frame(width: 80, alignment: .trailing)
            PillButton(title: "Encerrar", prominent: false) {
                if Perf.quit(app) { state.toast = "\(app.name) encerrado — se tiver algo sem salvar, ele vai perguntar." }
            }
        }
        .padding(.vertical, 6)
    }

    private var agents: some View {
        GlassCard(padding: 12) {
            LazyVStack(spacing: 0) {
                ForEach(state.launchItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.userOwned ? "person.fill" : "lock.fill")
                            .foregroundStyle(Color.ink.opacity(item.userOwned ? 1 : 0.5)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).lineLimit(1)
                            Text(item.program).font(.caption).foregroundStyle(Color.ink.opacity(0.74)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(item.scope).font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                        if item.userOwned { PillButton(title: "Remover", prominent: false) { pending = item } }
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(Color.ink.opacity(0.08))
                }
            }
        }
    }
}

// MARK: - Preparar para exportar

struct PrepareExportSheet: View {
    let heavy: [HeavyApp]
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var needGB: Double = 20
    @State private var toQuit: Set<String> = []
    @State private var freeRAM = true
    @State private var running = false

    /// Apps de criação ficam protegidos (não aparecem para fechar).
    private var candidates: [HeavyApp] {
        let keep = ["Premiere", "After Effects", "Media Encoder", "DaVinci", "Final Cut", "CapCut", "Photoshop", "Illustrator", "Finder"]
        return heavy.filter { app in !keep.contains { app.name.contains($0) } }.prefix(8).map { $0 }
    }

    var body: some View {
        let need = Int64(needGB * 1_000_000_000)
        let enough = monitor.diskFree >= need
        VStack(alignment: .leading, spacing: 16) {
            Text("Preparar para exportar").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Quanto espaço o export vai precisar?").font(.headline)
                HStack {
                    Slider(value: $needGB, in: 5...200, step: 5)
                    Text("\(Int(needGB)) GB").monospacedDigit().frame(width: 60)
                }
                Label(enough ? "Você tem \(FS.fmt(monitor.diskFree)) livres — dá conta."
                             : "Faltam \(FS.fmt(need - monitor.diskFree)). Libere espaço antes de exportar.",
                      systemImage: enough ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(enough ? Theme.teal : Theme.warm)
                if !enough {
                    HStack {
                        Button("Ir para Limpeza") { state.section = .cleanup; dismiss() }
                        Button("Mandar arquivos para a nuvem") { state.section = .cloud; dismiss() }
                    }
                }
            }

            Divider()
            Text("Fechar apps pesados").font(.headline)
            Text("Apps de criação (Premiere, After Effects, Photoshop…) nunca aparecem aqui.").font(.caption).foregroundStyle(.secondary)
            ForEach(candidates) { app in
                Toggle(isOn: Binding(get: { toQuit.contains(app.path) },
                                     set: { if $0 { toQuit.insert(app.path) } else { toQuit.remove(app.path) } })) {
                    HStack {
                        Image(nsImage: IconCache.icon( app.path)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Text(FS.fmt(app.memory)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Toggle("Liberar memória RAM no final (pede sua senha)", isOn: $freeRAM).toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button(running ? "Preparando…" : "Preparar") {
                    running = true
                    Task {
                        var closed = 0
                        for app in candidates where toQuit.contains(app.path) { if Perf.quit(app) { closed += 1 } }
                        if freeRAM {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await state.runAdminTask("Memória", "/usr/sbin/purge")
                        }
                        state.toast = "Pronto para exportar · \(closed) app(s) fechado(s) · \(FS.fmt(monitor.diskFree)) livres"
                        running = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
