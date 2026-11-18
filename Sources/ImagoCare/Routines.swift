import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Modelos

enum RoutineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case installers, screenshots, aiGens, downloads, caches
    var id: String { rawValue }

    var title: String {
        switch self {
        case .installers: "Instaladores usados"
        case .screenshots: "Capturas de tela antigas"
        case .aiGens: "Gerações de IA antigas"
        case .downloads: "Downloads antigos"
        case .caches: "Caches e logs"
        }
    }
    var detail: String {
        switch self {
        case .installers: "Arquivos .dmg, .pkg e .iso no Downloads — depois de instalar, não servem para mais nada."
        case .screenshots: "Capturas e gravações de tela na Mesa e no Downloads."
        case .aiGens: "Imagens e vídeos de Higgsfield, Midjourney, ChatGPT e afins no Downloads e na Mesa."
        case .downloads: "Tudo que está parado no Downloads (arquivos e pastas)."
        case .caches: "Caches de apps, logs e lixo do Xcode. Os apps recriam o que precisarem."
        }
    }
    var icon: String {
        switch self {
        case .installers: "shippingbox.fill"
        case .screenshots: "camera.viewfinder"
        case .aiGens: "wand.and.stars"
        case .downloads: "arrow.down.circle.fill"
        case .caches: "archivebox.fill"
        }
    }
    var defaultDays: Int {
        switch self {
        case .installers: 3
        case .screenshots: 7
        case .aiGens: 14
        case .downloads: 30
        case .caches: 7
        }
    }
    var actions: [RoutineAction] {
        switch self {
        case .installers: [.trash]
        case .screenshots, .aiGens, .downloads: [.drive, .trash]
        case .caches: [.delete]
        }
    }
    /// Caches rodam "a cada N dias"; o resto pega itens "com mais de N dias".
    var isPeriodic: Bool { self == .caches }
}

enum RoutineAction: String, Codable, Sendable {
    case trash, drive, delete
    var label: String {
        switch self {
        case .trash: "Lixeira"
        case .drive: "Google Drive"
        case .delete: "Apagar"
        }
    }
}

struct Routine: Codable, Identifiable, Sendable {
    var id: RoutineKind { kind }
    let kind: RoutineKind
    var enabled = false
    var days: Int
    var action: RoutineAction
    var lastRun: Date?

    init(kind: RoutineKind) {
        self.kind = kind
        days = kind.defaultDays
        action = kind.actions[0]
    }
}

struct RoutineLog: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let kind: RoutineKind
    let count: Int
    let bytes: Int64
    let action: RoutineAction
    var note: String = ""
}

// MARK: - Motor

enum RoutineEngine {
    static let home = FS.home
    static let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    static let screenshotPrefixes = ["captura de tela", "screenshot", "gravação de tela", "gravacao de tela",
                                     "screen recording", "cleanshot", "screen shot"]

    /// Mudança mais recente do item ou de qualquer coisa dentro dele (até 5 mil itens).
    static func latestChange(_ url: URL) -> Date {
        var latest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard let e = FS.fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [],
                                       errorHandler: { _, _ in true }) else { return latest }
        var n = 0
        for case let f as URL in e {
            if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > latest { latest = m }
            n += 1
            if n > 5000 { return .distantFuture }   // pasta enorme: trata como "em uso" por segurança
        }
        return latest
    }

    /// Chegada mais recente de qualquer coisa dentro de uma pasta (até 5 mil itens).
    static func newestArrival(_ url: URL) -> Date {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let e = FS.fm.enumerator(at: url, includingPropertiesForKeys: [.addedToDirectoryDateKey, .creationDateKey],
                                       options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return .distantPast }
        var newest = Date.distantPast, n = 0
        for case let f as URL in e {
            if let d = arrival(f), d > newest { newest = d }
            n += 1
            if n > 5000 { return .distantFuture }
        }
        return newest
    }

    /// Data em que o item chegou na pasta (ou a criação, se não houver).
    static func arrival(_ url: URL) -> Date? {
        let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return v?.addedToDirectoryDate ?? v?.creationDate
    }

    /// Itens da pasta (primeiro nível) que chegaram há mais de `days` dias.
    private static func topLevel(_ folder: String, olderThan days: Int, where match: (URL) -> Bool) -> [FileItem] {
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        let recent = Date().addingTimeInterval(-3600)
        var out: [FileItem] = []
        for u in FS.children(home.appendingPathComponent(folder)) {
            let n = u.lastPathComponent
            guard !n.hasPrefix("."), !partial.contains(u.pathExtension.lowercased()), match(u) else { continue }
            guard let d = arrival(u), d < limit else { continue }
            // pastas do próprio app (Organizar, Baixar vídeo) nunca entram na rotina
            let isFolder = (try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
            if isFolder && (Organizer.isOrganizerFolder(n) || n == "Limpo e Voando") { continue }
            // pasta antiga com arquivo que chegou recentemente dentro dela: fica
            if newestArrival(u) > limit { continue }
            // não mexe em nada alterado na última hora (pode estar em uso) — inclusive dentro de pastas
            if latestChange(u) > recent { continue }
            out.append(FileItem(url: u, size: FS.size(of: u), modified: d))
        }
        return out
    }

    static func candidates(_ r: Routine) -> [FileItem] {
        switch r.kind {
        case .installers:
            let ext: Set<String> = ["dmg", "pkg", "mpkg", "iso"]
            return topLevel("Downloads", olderThan: r.days) { ext.contains($0.pathExtension.lowercased()) }
        case .screenshots:
            let media: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "mov", "mp4"]
            let isShot: (URL) -> Bool = { u in
                let n = u.lastPathComponent.lowercased()
                let isFile = (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                return isFile && media.contains(u.pathExtension.lowercased()) && screenshotPrefixes.contains { n.hasPrefix($0) }
            }
            return topLevel("Desktop", olderThan: r.days, where: isShot) + topLevel("Downloads", olderThan: r.days, where: isShot)
        case .aiGens:
            let limit = Date().addingTimeInterval(-Double(r.days) * 86_400)
            return Scanner.aiGenerations(topLevelOnly: true).filter { ($0.modified ?? .distantFuture) < limit && !CloudEngine.isCloud($0.url) }
        case .downloads:
            return topLevel("Downloads", olderThan: r.days) { !CloudEngine.isCloud($0) }
        case .caches:
            return Scanner.scanJunk().filter { $0.preselect && $0.removal == .delete }.flatMap(\.items)
        }
    }

    /// Hora de rodar? Rotinas de arquivos: 1x por dia. Caches: a cada N dias.
    static func isDue(_ r: Routine, now: Date = Date()) -> Bool {
        guard r.enabled else { return false }
        guard let last = r.lastRun else { return true }
        let interval = r.kind.isPeriodic ? Double(r.days) * 86_400 : 20 * 3600
        return now.timeIntervalSince(last) >= interval
    }
}

// MARK: - Estado e agendador

extension AppState {
    static let routinesKey = "routines.v1"
    static let routineLogKey = "routineLog.v1"

    static func loadRoutines() -> [Routine] {
        let saved = (UserDefaults.standard.data(forKey: routinesKey))
            .flatMap { try? JSONDecoder().decode([Routine].self, from: $0) } ?? []
        return RoutineKind.allCases.map { k in
            var r = saved.first { $0.kind == k } ?? Routine(kind: k)
            if !k.actions.contains(r.action) { r.action = k.actions[0] }   // nunca "apagar" onde não é permitido
            r.days = min(365, max(1, r.days))
            return r
        }
    }

    static func loadRoutineLog() -> [RoutineLog] {
        (UserDefaults.standard.data(forKey: routineLogKey))
            .flatMap { try? JSONDecoder().decode([RoutineLog].self, from: $0) } ?? []
    }

    func saveRoutines() {
        if let d = try? JSONEncoder().encode(routines) { UserDefaults.standard.set(d, forKey: Self.routinesKey) }
        if let d = try? JSONEncoder().encode(Array(routineLog.prefix(200))) { UserDefaults.standard.set(d, forKey: Self.routineLogKey) }
    }

    var routinesFreedThisWeek: Int64 {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        return routineLog.filter { $0.date > weekAgo }.reduce(0) { $0 + $1.bytes }
    }

    func updateRoutine(_ kind: RoutineKind, _ change: (inout Routine) -> Void) {
        guard let i = routines.firstIndex(where: { $0.kind == kind }) else { return }
        change(&routines[i])
        saveRoutines()
    }

    /// Roda em segundo plano enquanto o app estiver aberto: confere a cada 30 min.
    func startRoutineLoop() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // espera o app abrir com calma
            while true {
                await runDueRoutines()
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            }
        }
    }

    func runDueRoutines() async {
        await runOrganizerIfDue()
        for r in routines where RoutineEngine.isDue(r) {
            await runRoutine(r.kind, automatic: true)
        }
    }

    func runRoutine(_ kind: RoutineKind, automatic: Bool = false) async {
        guard let r = routines.first(where: { $0.kind == kind }), !routineRunning.contains(kind) else { return }
        routineRunning.insert(kind)
        defer { routineRunning.remove(kind) }

        let items = await Task.detached { RoutineEngine.candidates(r) }.value
        var log = RoutineLog(date: Date(), kind: kind, count: 0, bytes: 0, action: r.action)

        if !items.isEmpty {
            switch r.action {
            case .trash, .delete:
                let res = await measured("Rotina: \(kind.title)") {
                    await Task.detached { FS.remove(items, permanently: r.action == .delete) }.value
                }
                log = RoutineLog(date: Date(), kind: kind, count: res.count, bytes: res.freed, action: r.action,
                                 note: res.failures.isEmpty ? "" : "\(res.failures.count) não puderam ser movidos")
            case .drive:
                // a rotina procura o próprio Google Drive, sem mexer no destino escolhido na tela Nuvem
                let google = CloudEngine.destinations().first { $0.name == "Google Drive" }
                if let google {
                    log = RoutineLog(date: Date(), kind: kind, count: items.count, bytes: items.reduce(0) { $0 + $1.size },
                                     action: .drive, note: "enviados para Meu Drive › Arquivo do Mac")
                    Task { await self.sendToCloud(items, to: google) }   // espera o upload em segundo plano e libera o espaço
                } else {
                    log.note = "Google Drive não encontrado — nada foi movido"
                }
            }
        }
        updateRoutine(kind) { $0.lastRun = Date() }
        if log.count > 0 || !log.note.isEmpty || !automatic {
            routineLog.insert(log, at: 0)
            if routineLog.count > 200 { routineLog.removeLast(routineLog.count - 200) }
            saveRoutines()
        }
        if log.count > 0 {
            if log.action == .drive { toast = "Rotina \"\(kind.title)\": \(log.count) itens indo para o Drive" }
        } else if !automatic {
            toast = "Rotina \"\(kind.title)\": nada para fazer agora"
        }
        await previewRoutine(kind)
    }

    func previewRoutine(_ kind: RoutineKind) async {
        guard let r = routines.first(where: { $0.kind == kind }) else { return }
        let items = await Task.detached { RoutineEngine.candidates(r) }.value
        routinePreview[kind] = items
    }
}

// MARK: - Abrir ao ligar o Mac

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Tela

struct RoutinesView: View {
    @EnvironmentObject var state: AppState
    @State private var loginOn = LoginItem.isOn
    @State private var confirmRun: RoutineKind?
    @State private var expanded: RoutineKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ROTINAS AUTOMÁTICAS").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(Color.ink.opacity(0.76))
                        Text("Configure uma vez. O app cuida do resto.").font(.system(size: 30, weight: .light))
                        Text("Elas rodam sozinhas enquanto o Limpo e Voando estiver aberto ou na barra de menus. Tudo que vai para a Lixeira pode ser recuperado.")
                            .font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76)).frame(maxWidth: 560, alignment: .leading)
                    }
                    Spacer()
                    GlassCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Liberado nos últimos 7 dias").font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                            Text(FS.fmt(state.routinesFreedThisWeek)).font(.system(size: 26, weight: .light)).monospacedDigit()
                            Toggle("Abrir ao ligar o Mac", isOn: $loginOn)
                                .toggleStyle(.switch).controlSize(.small)
                                .onChange(of: loginOn) { on in
                                    if let err = LoginItem.set(on) {
                                        state.toast = "Não consegui ajustar: \(err)"
                                        loginOn = LoginItem.isOn
                                    }
                                }
                        }
                    }
                    .frame(width: 240)
                }
                .padding(.top, 30)

                ForEach(state.routines) { r in card(r) }

                if !state.routineLog.isEmpty { history }
            }
            .padding(.horizontal, 30).padding(.bottom, 30)
        }
        .confirmationDialog("Rodar \"\(confirmRun?.title ?? "")\" agora?",
                            isPresented: Binding(get: { confirmRun != nil }, set: { if !$0 { confirmRun = nil } })) {
            Button("Rodar agora") { if let k = confirmRun { Task { await state.runRoutine(k) } } }
        } message: {
            if let k = confirmRun, let items = state.routinePreview[k] {
                Text("\(items.count) itens · \(FS.fmt(items.reduce(0) { $0 + $1.size })).")
            }
        }
    }

    private func card(_ r: Routine) -> some View {
        let preview = state.routinePreview[r.kind]
        let tint = Section.cleanup.accent
        return GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    GlassHero(symbol: r.kind.icon, tint: r.enabled ? tint : .gray, radius: 60, size: 46, animated: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.kind.title).font(.system(size: 16, weight: .semibold))
                        Text(r.kind.detail).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { r.enabled }, set: { on in state.updateRoutine(r.kind) { $0.enabled = on } }))
                        .toggleStyle(.switch).labelsHidden()
                }

                HStack(spacing: 10) {
                    Text(r.kind.isPeriodic ? "A cada" : "Itens com mais de").font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.8))
                    Stepper(value: Binding(get: { r.days }, set: { v in state.updateRoutine(r.kind) { $0.days = v }; state.routinePreview[r.kind] = nil }),
                            in: 1...365) {
                        Text("\(r.days) dia\(r.days == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    .fixedSize()
                    Text("→").foregroundStyle(Color.ink.opacity(0.74))
                    if r.kind.actions.count > 1 {
                        Picker("", selection: Binding(get: { r.action }, set: { a in state.updateRoutine(r.kind) { $0.action = a } })) {
                            ForEach(r.kind.actions, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    } else {
                        Text(r.action.label).font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    if let last = r.lastRun {
                        Text("Última vez: \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                    }
                }

                HStack(spacing: 10) {
                    if state.routineRunning.contains(r.kind) {
                        ProgressView().controlSize(.small)
                        Text("Rodando…").font(.caption)
                    } else if let p = preview {
                        Button {
                            withAnimation { expanded = expanded == r.kind ? nil : r.kind }
                        } label: {
                            Label(p.isEmpty ? "Nada para fazer agora"
                                            : "Agora pegaria \(p.count) itens · \(FS.fmt(p.reduce(0) { $0 + $1.size }))",
                                  systemImage: p.isEmpty ? "checkmark.circle" : "eye")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(p.isEmpty ? Theme.teal : Color.ink)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("Calculando prévia…").font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                    }
                    Spacer()
                    PillButton(title: "Rodar agora", prominent: false,
                               enabled: !(preview?.isEmpty ?? true) && !state.routineRunning.contains(r.kind)) {
                        confirmRun = r.kind
                    }
                }

                if expanded == r.kind, let p = preview, !p.isEmpty {
                    Divider().overlay(Color.ink.opacity(0.12))
                    VStack(spacing: 0) {
                        ForEach(p.prefix(30)) { ItemRow(item: $0, selectable: false) }
                        if p.count > 30 { Text("+ \(p.count - 30) itens").font(.caption).foregroundStyle(Color.ink.opacity(0.74)).padding(6) }
                    }
                }
            }
        }
        .opacity(r.enabled ? 1 : 0.85)
        .task(id: "\(r.kind.rawValue)-\(r.days)") {
            if state.routinePreview[r.kind] == nil { await state.previewRoutine(r.kind) }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Histórico").font(.headline).padding(.top, 8)
            GlassCard(padding: 12) {
                VStack(spacing: 0) {
                    ForEach(state.routineLog.prefix(20)) { log in
                        HStack(spacing: 10) {
                            Image(systemName: log.kind.icon).frame(width: 20).foregroundStyle(Color.ink.opacity(0.8))
                            Text(log.kind.title).lineLimit(1)
                            Text(log.count > 0 ? "\(log.count) itens → \(log.action.label)" : (log.note.isEmpty ? "nada para fazer" : log.note))
                                .font(.caption).foregroundStyle(Color.ink.opacity(0.76)).lineLimit(1)
                            Spacer()
                            if log.bytes > 0 { Text(FS.fmt(log.bytes)).font(.caption).monospacedDigit() }
                            Text(log.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                        }
                        .padding(.vertical, 6)
                        Divider().overlay(Color.ink.opacity(0.06))
                    }
                }
            }
        }
    }
}
