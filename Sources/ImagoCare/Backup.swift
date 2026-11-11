import SwiftUI
import AppKit

// MARK: - Modelos

struct BackupConfig: Codable, Sendable {
    var folders: [String] = []
    var enabled = false
    var frequency = 0            // 0 = diário, 1 = semanal
    var weekday = 2              // 1 = domingo … 7 = sábado (Calendar)
    var hour = 22
    var minute = 0
    var enabledAt: Date?
    var lastRun: Date?
    /// nil/0 = manter nos dois (cópia) · 1 = mover para o Drive e liberar o Mac
    var mode: Int?
    var moves: Bool { mode == 1 }
}

struct BackupEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let files: Int
    let bytes: Int64
    let failures: Int
    var note = ""
}

struct BackupProgress: Sendable {
    var phase = ""
    var done = 0
    var total = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : (total > 0 ? Double(done) / Double(total) : 0) }
}

// MARK: - Motor

enum BackupEngine {
    struct Item: Sendable { let src: URL; let dst: URL; let size: Int64; let modified: Date? }

    static let skipNames: Set<String> = ["node_modules", ".git", ".Trash", "Caches", ".build", "DerivedData", ".DS_Store"]
    static let batchLimit: Int64 = 2 * 1024 * 1024 * 1024       // 2 GB por lote
    static let reserve: Int64 = 3 * 1024 * 1024 * 1024          // nunca deixa o disco com menos de 3 GB

    static func destination(_ driveRoot: URL) -> URL { driveRoot.appendingPathComponent("Backups do Mac") }

    /// Pastas que nunca podem entrar no backup (sistema, raiz, home inteira, Library, nuvem).
    static func isAllowed(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FS.home.path
        guard !p.isEmpty, p != "/", p != home, !home.hasPrefix(p + "/") else { return false }
        let blocked = ["/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/Volumes",
                       home + "/Library", home + "/.Trash"]
        if blocked.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return false }
        return !CloudEngine.isCloud(url)
    }

    /// Destino espelha o caminho a partir da home: ~/Documents/Clientes → Backups do Mac/Documents/Clientes
    /// (duas pastas "Clientes" em lugares diferentes nunca se sobrescrevem).
    static func base(for folder: URL, in dest: URL) -> URL {
        let p = folder.standardizedFileURL.path, home = FS.home.path
        let rel = p.hasPrefix(home + "/") ? String(p.dropFirst(home.count + 1)) : folder.lastPathComponent
        return dest.appendingPathComponent(rel)
    }

    /// O que é novo ou mudou desde o último backup (compara tamanho e data, sem baixar nada da nuvem).
    static func plan(folders: [URL], dest: URL, moveAll: Bool = false) -> [Item] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        var out: [Item] = []
        for folder in folders where isAllowed(folder) {
            let base = base(for: folder, in: dest)
            guard let e = FS.fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                                           errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
                if skipNames.contains(u.lastPathComponent) { if v.isDirectory == true { e.skipDescendants() }; continue }
                let isPackage = v.isPackage == true
                if v.isDirectory == true && !isPackage { continue }
                if isPackage { e.skipDescendants() }
                guard v.isRegularFile == true || isPackage else { continue }

                let rel = String(u.path.dropFirst(folder.path.count + 1))
                let dst = base.appendingPathComponent(rel)
                let size = isPackage ? FS.size(of: u) : Int64(v.fileSize ?? 0)
                let mod = v.contentModificationDate
                // arquivo sendo gravado agora (export, autosave): fica para o próximo backup
                if let m = mod, Date().timeIntervalSince(m) < 600 { continue }
                if moveAll || needsCopy(dst: dst, size: size, modified: mod, package: isPackage) {
                    out.append(Item(src: u, dst: dst, size: size, modified: mod))
                }
            }
        }
        return out
    }

    private static func needsCopy(dst: URL, size: Int64, modified: Date?, package: Bool) -> Bool {
        guard FS.fm.fileExists(atPath: dst.path) else { return true }
        let v = try? dst.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let m = modified, let dm = v?.contentModificationDate, m.timeIntervalSince(dm) > 2 { return true }
        if !package, let ds = v?.fileSize, Int64(ds) != size { return true }
        return false
    }

    /// Copia (manter nos dois) ou move (liberar o Mac) um item para o Drive.
    static func transfer(_ it: Item, move: Bool) -> String? {
        do {
            try FS.fm.createDirectory(at: it.dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if move {
                // mover nunca apaga nada no destino: se já existe, ganha um nome novo
                var dst = it.dst
                var i = 2
                while FS.fm.fileExists(atPath: dst.path) {
                    let b = it.dst.deletingPathExtension().lastPathComponent, e = it.dst.pathExtension
                    dst = it.dst.deletingLastPathComponent().appendingPathComponent(e.isEmpty ? "\(b) \(i)" : "\(b) \(i).\(e)")
                    i += 1
                }
                try FS.fm.moveItem(at: it.src, to: dst)   // mesmo disco: instantâneo e sem espaço extra
                return nil
            }
            if FS.fm.fileExists(atPath: it.dst.path) { try FS.fm.removeItem(at: it.dst) }   // versão antiga vai para a Lixeira do Drive
            try FS.fm.copyItem(at: it.src, to: it.dst)
            if let m = it.modified { try? FS.fm.setAttributes([.modificationDate: m], ofItemAtPath: it.dst.path) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Próximo horário a partir de uma data.
    static func next(after date: Date, _ c: BackupConfig) -> Date {
        var comps = DateComponents(hour: c.hour, minute: c.minute)
        if c.frequency == 1 { comps.weekday = c.weekday }
        return Calendar.current.nextDate(after: date, matching: comps, matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    static func nextRun(_ c: BackupConfig) -> Date? {
        guard c.enabled, !c.folders.isEmpty else { return nil }
        return next(after: c.lastRun ?? c.enabledAt ?? Date(), c)
    }
}

// MARK: - Estado

extension AppState {
    static let backupKey = "backup.config.v1"
    static let backupLogKey = "backup.log.v1"

    static func loadBackup() -> BackupConfig {
        (UserDefaults.standard.data(forKey: backupKey)).flatMap { try? JSONDecoder().decode(BackupConfig.self, from: $0) } ?? BackupConfig()
    }
    static func loadBackupLog() -> [BackupEntry] {
        (UserDefaults.standard.data(forKey: backupLogKey)).flatMap { try? JSONDecoder().decode([BackupEntry].self, from: $0) } ?? []
    }

    func saveBackup() {
        if let d = try? JSONEncoder().encode(backup) { UserDefaults.standard.set(d, forKey: Self.backupKey) }
        if let d = try? JSONEncoder().encode(Array(backupLog.prefix(100))) { UserDefaults.standard.set(d, forKey: Self.backupLogKey) }
    }

    func editBackup(_ change: (inout BackupConfig) -> Void) {
        let before = (backup.folders, backup.mode)
        change(&backup)
        saveBackup()
        if before.0 != backup.folders || before.1 != backup.mode { backupPreview = nil }
    }

    /// Confere a cada minuto se chegou a hora (inclusive se o Mac estava desligado no horário).
    func startBackupLoop() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            while true {
                if let next = BackupEngine.nextRun(backup), Date() >= next, !backupRunning {
                    await runBackup()
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func previewBackup() async {
        guard let drive = driveRoot else { return }
        let folders = backup.folders.map { URL(fileURLWithPath: $0) }
        let dest = BackupEngine.destination(drive)
        let moveAll = backup.moves
        let items = await Task.detached { BackupEngine.plan(folders: folders, dest: dest, moveAll: moveAll) }.value
        backupPreview = (items.count, items.reduce(0) { $0 + $1.size })
    }

    func runBackup() async {
        if backup.moves {
            await measured("Backup: mover para o Drive", settle: 3) { await backupPass() }
        } else {
            _ = await backupPass()
        }
    }

    private func backupPass() async -> CleanResult {
        guard !backupRunning else { return CleanResult() }
        let folders = backup.folders.map { URL(fileURLWithPath: $0) }
            .filter { FS.fm.fileExists(atPath: $0.path) && BackupEngine.isAllowed($0) }
        guard let drive = driveRoot, !folders.isEmpty else {
            // registra a tentativa para não repetir (e avisar) a cada minuto
            backup.lastRun = Date()
            backupLog.insert(BackupEntry(date: Date(), files: 0, bytes: 0, failures: 1,
                                         note: driveRoot == nil ? "Google Drive não encontrado" : "Nenhuma pasta disponível"), at: 0)
            saveBackup()
            toast = driveRoot == nil ? "Backup não rodou: Google Drive não encontrado." : "Backup não rodou: nenhuma pasta disponível."
            return CleanResult()
        }
        let move = backup.moves

        backupRunning = true
        backupProgress = BackupProgress(phase: "Comparando com o último backup…")
        let dest = BackupEngine.destination(drive)
        let items = await Task.detached { BackupEngine.plan(folders: folders, dest: dest, moveAll: move) }.value
        backupProgress.total = items.count
        backupProgress.bytesTotal = items.reduce(0) { $0 + $1.size }

        var failures = 0, done = 0
        var bytes: Int64 = 0
        var pending: [URL] = []
        var pendingBytes: Int64 = 0

        for it in items {
            // lote cheio ou disco apertado: espera o Drive receber e libera o espaço antes de continuar
            if !pending.isEmpty && (pendingBytes + it.size > BackupEngine.batchLimit || Disk.free() < it.size + BackupEngine.reserve) {
                let f = await flushBackup(pending)
                failures += f; done = max(0, done - f)
                pending = []; pendingBytes = 0
            }
            if !move && Disk.free() < it.size + BackupEngine.reserve {   // mover não precisa de espaço extra
                failures += 1
                continue
            }
            backupProgress.phase = "\(move ? "Movendo" : "Copiando") \(it.src.lastPathComponent)…"
            let err = await Task.detached { BackupEngine.transfer(it, move: move) }.value
            if err != nil { failures += 1 } else {
                pending.append(it.dst); pendingBytes += it.size
                done += 1; bytes += it.size
            }
            backupProgress.done = done + failures
            backupProgress.bytesDone += it.size
        }
        if !pending.isEmpty { let f = await flushBackup(pending); failures += f; done = max(0, done - f) }

        let entry = BackupEntry(date: Date(), files: done, bytes: bytes, failures: failures,
                                note: items.isEmpty ? "Tudo já estava no backup" : "")
        backupLog.insert(entry, at: 0)
        if backupLog.count > 100 { backupLog.removeLast(backupLog.count - 100) }
        backup.lastRun = Date()
        saveBackup()
        backupRunning = false
        await previewBackup()
        toast = items.isEmpty ? "Backup em dia — nada mudou desde o último."
            : "Backup concluído · \(done) arquivos · \(FS.fmt(bytes)) no Drive" + (failures > 0 ? " · \(failures) com erro" : "")
        return CleanResult(count: done, freed: move ? bytes : 0)
    }

    /// Espera o lote subir (até 2 h) e libera as cópias locais. Retorna quantos falharam.
    private func flushBackup(_ urls: [URL]) async -> Int {
        backupProgress.phase = "Enviando para o Google Drive…"
        var waiting = Set(urls)
        var failed = 0
        let limit = Date().addingTimeInterval(2 * 3600)
        while !waiting.isEmpty && Date() < limit {
            for u in waiting {
                let st = await Task.detached { CloudEngine.uploadState(u) }.value
                if st.error != nil { failed += 1; waiting.remove(u) }
                else if st.done {
                    await Task.detached { CloudEngine.evict(u) }.value
                    waiting.remove(u)
                }
            }
            if !waiting.isEmpty { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        return failed + waiting.count
    }
}

// MARK: - Tela

struct BackupView: View {
    @EnvironmentObject var state: AppState
    @State private var loginOn = LoginItem.isOn
    @State private var confirmMoveNow = false

    private let weekdays = ["Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if state.driveRoot == nil {
                    GlassCard {
                        Label("Google Drive não encontrado. Instale o Google Drive para computador e entre na sua conta.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(Theme.orange)
                    }
                }
                folders
                modeCard
                schedule
                if state.backupRunning { progressCard }
                if !state.backupLog.isEmpty { history }
            }
            .padding(.horizontal, 30).padding(.bottom, 30)
        }
        .task(id: "\(state.backup.folders)\(state.backup.moves)") { if !state.backupRunning && !state.backup.folders.isEmpty { await state.previewBackup() } }
        .confirmationDialog("Mover os arquivos para o Drive e tirar do Mac?", isPresented: $confirmMoveNow) {
            Button("Mover e liberar o Mac") { Task { await state.runBackup() } }
        } message: {
            Text("Os arquivos saem destas pastas e passam a ficar em Google Drive › Backups do Mac, com ícone de nuvem no Finder. Abrem normalmente quando você precisar (baixam na hora). O espaço do Mac só é liberado depois que o Drive confirmar o envio de cada arquivo.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(Section.backup.number).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Rectangle().fill(Color.ink.opacity(0.4)).frame(width: 22, height: 0.8)
                    Text("BACKUP").font(.system(size: 11, weight: .semibold)).tracking(2.2)
                }
                .foregroundStyle(Color.ink.opacity(0.76))
                Text("Suas pastas seguras na nuvem.").font(.system(size: 30, weight: .light))
                Text("Só o que é novo ou mudou sobe. Nada é apagado das pastas originais, e o espaço do Mac é liberado depois de cada envio.")
                    .font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76)).frame(maxWidth: 560, alignment: .leading)
            }
            Spacer()
            GlassCard(padding: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Próximo backup").font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                    if let next = BackupEngine.nextRun(state.backup) {
                        Text(next.formatted(.dateTime.weekday(.wide).hour().minute())).font(.system(size: 17, weight: .medium))
                    } else {
                        Text("Desligado").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.ink.opacity(0.74))
                    }
                    if let last = state.backup.lastRun {
                        Text("Último: \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                    }
                    PillButton(title: state.backupRunning ? "Fazendo backup…" : "Fazer backup agora", icon: "arrow.up.circle",
                               enabled: !state.backupRunning && !state.backup.folders.isEmpty && state.driveRoot != nil) {
                        if state.backup.moves { confirmMoveNow = true } else { Task { await state.runBackup() } }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(width: 250)
        }
        .padding(.top, 30)
    }

    private var folders: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Pastas").font(.headline)
                    Spacer()
                    PillButton(title: "Adicionar pasta…", icon: "plus", prominent: false) { pickFolders() }
                }
                if state.backup.folders.isEmpty {
                    HStack(spacing: 12) {
                        IconTile(symbol: "folder.badge.plus")
                        Text("Arraste pastas aqui ou use \"Adicionar pasta…\". Ex.: Documentos/Clientes, Projetos do Premiere.")
                            .font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76))
                    }
                    .padding(.vertical, 8)
                }
                ForEach(state.backup.folders, id: \.self) { path in
                    let url = URL(fileURLWithPath: path)
                    HStack(spacing: 12) {
                        Image(nsImage: IconCache.icon( path)).resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(path.replacingOccurrences(of: FS.home.path, with: "~")).font(.caption)
                                .foregroundStyle(Color.ink.opacity(0.74)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                        Text("Drive › Backups do Mac › \(BackupEngine.base(for: url, in: URL(fileURLWithPath: "/")).path.dropFirst())").font(.caption).foregroundStyle(Color.ink.opacity(0.74)).lineLimit(1)
                        Button { state.editBackup { $0.folders.removeAll { $0 == path } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.74)).help("Tirar do backup (nada é apagado)")
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(Theme.hairline)
                }
                if let p = state.backupPreview, !state.backup.folders.isEmpty {
                    Label(p.0 == 0 ? "Tudo já está no backup." : "Próximo backup vai \(state.backup.moves ? "mover" : "enviar") \(p.0) arquivos · \(FS.fmt(p.1))\(state.backup.moves ? " e liberar esse espaço do Mac" : "")",
                          systemImage: p.0 == 0 ? "checkmark.circle" : "arrow.up.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.0 == 0 ? Theme.green : Color.ink.opacity(0.8))
                } else if !state.backup.folders.isEmpty {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Calculando o que mudou…").font(.caption) }
                        .foregroundStyle(Color.ink.opacity(0.74))
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addFolders([url]) }
                }
            }
            return true
        }
    }

    private var modeCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Depois de enviar").font(.headline)
                HStack(spacing: 12) {
                    modeOption(0, "Manter nos dois", "externaldrive.badge.checkmark",
                               "O original fica no Mac. A cópia vai para o Drive e não ocupa espaço extra no disco.")
                    modeOption(1, "Mover e liberar o Mac", "icloud.and.arrow.up",
                               "Os arquivos saem do Mac e ficam só no Drive, abrindo quando você precisar. Ideal para exports e projetos entregues.")
                }
                if state.backup.moves {
                    Label("Nesse modo as pastas ficam vazias depois de cada backup — o conteúdo passa a morar no Drive › Backups do Mac.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.orange)
                }
            }
        }
    }

    private func modeOption(_ value: Int, _ title: String, _ icon: String, _ text: String) -> some View {
        let on = (state.backup.mode ?? 0) == value
        return Button { state.editBackup { $0.mode = value } } label: {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: icon, tint: on ? Theme.blue : nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Theme.blue : Color.ink.opacity(0.4))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ink.opacity(on ? 0.06 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? Theme.blue.opacity(0.7) : Color.ink.opacity(0.12), lineWidth: on ? 1.2 : 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var schedule: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Quando").font(.headline)
                    Spacer()
                    Toggle("Backup automático", isOn: Binding(get: { state.backup.enabled }, set: { on in
                        state.editBackup { $0.enabled = on; if on { $0.enabledAt = Date() } }
                    }))
                    .toggleStyle(.switch)
                }
                HStack(spacing: 12) {
                    Picker("", selection: Binding(get: { state.backup.frequency }, set: { v in state.editBackup { $0.frequency = v } })) {
                        Text("Todo dia").tag(0)
                        Text("Toda semana").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if state.backup.frequency == 1 {
                        Picker("", selection: Binding(get: { state.backup.weekday }, set: { v in state.editBackup { $0.weekday = v } })) {
                            ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Text("às").foregroundStyle(Color.ink.opacity(0.76))
                    DatePicker("", selection: Binding(get: {
                        Calendar.current.date(bySettingHour: state.backup.hour, minute: state.backup.minute, second: 0, of: Date()) ?? Date()
                    }, set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        state.editBackup { $0.hour = c.hour ?? 22; $0.minute = c.minute ?? 0 }
                    }), displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
                    Spacer()
                }
                Divider().overlay(Theme.hairline)
                HStack {
                    Label("Se o Mac estiver desligado na hora, o backup roda assim que ele ligar.", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.76))
                    Spacer()
                    Toggle("Abrir ao ligar o Mac", isOn: $loginOn).toggleStyle(.switch).controlSize(.small)
                        .onChange(of: loginOn) { on in
                            if let err = LoginItem.set(on) { state.toast = "Não consegui ajustar: \(err)"; loginOn = LoginItem.isOn }
                        }
                }
            }
        }
    }

    private var progressCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(state.backupProgress.phase).font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.8)).lineLimit(1)
                    Spacer()
                    Text("\(Int(state.backupProgress.fraction * 100))%").font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                }
                ProgressView(value: state.backupProgress.fraction).tint(Theme.blue)
                Text("\(state.backupProgress.done) de \(state.backupProgress.total) arquivos · \(FS.fmt(state.backupProgress.bytesDone)) de \(FS.fmt(state.backupProgress.bytesTotal)) · deixe o app aberto")
                    .font(.caption).foregroundStyle(Color.ink.opacity(0.74))
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Histórico").font(.headline).padding(.top, 6)
            GlassCard(padding: 12) {
                VStack(spacing: 0) {
                    ForEach(state.backupLog.prefix(15)) { e in
                        HStack(spacing: 10) {
                            Image(systemName: e.failures > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                                .foregroundStyle(e.failures > 0 ? Theme.orange : Theme.green)
                            Text(e.date.formatted(date: .abbreviated, time: .shortened))
                            Text(e.note.isEmpty ? "\(e.files) arquivos · \(FS.fmt(e.bytes))" : e.note)
                                .font(.caption).foregroundStyle(Color.ink.opacity(0.76))
                            Spacer()
                            if e.failures > 0 { Text("\(e.failures) com erro").font(.caption).foregroundStyle(Theme.orange) }
                        }
                        .padding(.vertical, 7)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            if let drive = state.driveRoot {
                Button { NSWorkspace.shared.activateFileViewerSelecting([BackupEngine.destination(drive)]) } label: {
                    Label("Abrir \"Backups do Mac\" no Finder", systemImage: "folder").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.blue)
            }
        }
    }

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adicionar ao backup"
        panel.message = "Escolha as pastas que vão para o backup no Google Drive"
        if panel.runModal() == .OK { addFolders(panel.urls) }
    }

    private func addFolders(_ urls: [URL]) {
        for u in urls {
            var isDir: ObjCBool = false
            guard FS.fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if CloudEngine.isCloud(u) { state.toast = "\(u.lastPathComponent) já está na nuvem."; continue }
            let p = u.standardizedFileURL.path
            if state.backup.folders.contains(where: { p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }) {
                state.toast = "\(u.lastPathComponent) está dentro de outra pasta do backup (ou contém uma)."
                continue
            }
            guard BackupEngine.isAllowed(u) else {
                state.toast = "Por segurança, \(u.lastPathComponent) não pode entrar no backup (pasta do sistema, home inteira ou Biblioteca)."
                continue
            }
            if !state.backup.folders.contains(u.path) { state.editBackup { $0.folders.append(u.path) } }
        }
    }
}
