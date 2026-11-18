import SwiftUI
import SystemConfiguration
import AppKit
import Darwin

// MARK: - Seções (cada uma com cor e tela de abertura próprias)

enum SectionTone {
    case light, dark, navy
    /// Preto e azul-marinho usam texto branco; branco usa texto preto.
    var scheme: ColorScheme { self == .light ? .light : .dark }
}

enum Section: String, CaseIterable, Identifiable {
    case home, cleanup, performance, routines, organize, apps, clutter, lens, cloud, compress, download, backup, phone, tools, activity
    var id: String { rawValue }

    /// Núcleo do app: limpeza e desempenho.
    static let main: [Section] = [.home, .cleanup, .performance, .routines, .organize, .lens, .clutter, .apps]
    /// Processos rápidos (secundários).
    static let quick: [Section] = [.cloud, .backup, .compress, .download, .phone]

    var title: String {
        switch self {
        case .home: "Cuidado inteligente"
        case .cleanup: "Limpeza"
        case .performance: "Desempenho"
        case .apps: "Aplicativos"
        case .clutter: "Acúmulos"
        case .lens: "Lupa de espaço"
        case .cloud: "Nuvem"
        case .routines: "Rotinas"
        case .organize: "Organizar"
        case .phone: "Celular · Bônus (teste)"
        case .backup: "Backup"
        case .compress: "Compressor"
        case .download: "Baixar vídeo"
        case .tools: "Ferramentas"
        case .activity: "Atividades"
        }
    }

    var icon: String {
        switch self {
        case .home: "sparkles"
        case .cleanup: "bubbles.and.sparkles.fill"
        case .performance: "bolt.fill"
        case .apps: "square.grid.2x2.fill"
        case .clutter: "folder.fill"
        case .lens: "circle.dashed.inset.filled"
        case .cloud: "icloud.and.arrow.up.fill"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .download: "arrow.down.circle.fill"
        case .routines: "clock.arrow.2.circlepath"
        case .organize: "tray.2.fill"
        case .phone: "iphone"
        case .backup: "externaldrive.badge.icloud"
        case .tools: "square.stack.3d.up.fill"
        case .activity: "chart.line.uptrend.xyaxis"
        }
    }

    var heroSymbol: String {
        switch self {
        case .home: "sparkles"
        case .cleanup: "bubbles.and.sparkles.fill"
        case .performance: "bolt.fill"
        case .apps: "xmark.app.fill"
        case .clutter: "folder.fill"
        case .lens: "magnifyingglass"
        case .cloud: "icloud.and.arrow.up.fill"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .download: "arrow.down.to.line"
        case .routines: "clock.arrow.2.circlepath"
        case .organize: "tray.2.fill"
        case .phone: "iphone"
        case .backup: "externaldrive.badge.icloud"
        case .tools: "square.stack.3d.up.fill"
        case .activity: "chart.line.uptrend.xyaxis"
        }
    }

    var pitch: String {
        switch self {
        case .home: "Uma passada rápida para cuidar do essencial do seu Mac."
        case .cleanup: "Tire do caminho o que só ocupa espaço e recupere gigas."
        case .performance: "Deixe o Mac leve com as manutenções certas."
        case .apps: "Remova apps por completo, sem deixar restos para trás."
        case .clutter: "Encontre arquivos pesados e cópias esquecidas."
        case .lens: "Veja o que ocupa mais espaço e decida o que fica."
        case .backup: "Suas pastas seguras na nuvem, no horário que você escolher."
        case .phone: "Fotos do celular no Drive, celular leve."
        case .organize: "Cada arquivo no seu lugar, por tipo ou por data."
        case .routines: "Configure uma vez e o Mac se mantém limpo sozinho."
        case .compress: "Deixe vídeos e PDFs mais leves sem perder qualidade visível."
        case .download: "Cole o link e baixe o vídeo na maior qualidade, até 4K."
        case .cloud: "Mande os arquivos pesados para a nuvem e libere espaço de verdade."
        case .tools: "Todas as ferramentas do Limpo e Voando num só lugar."
        case .activity: "Como o seu Mac está e o que o Limpo e Voando já fez."
        }
    }

    var features: [(String, String)] {
        switch self {
        case .home: [("Análise de limpeza", "bubbles.and.sparkles.fill"),
                     ("Acúmulos e duplicados", "folder.fill"),
                     ("Itens de inicialização", "bolt.fill")]
        case .cleanup: [("Caches de apps", "archivebox.fill"),
                        ("Logs do usuário", "doc.text.fill"),
                        ("Cache de mídia Adobe", "film.fill"),
                        ("Caches de IA e desenvolvimento", "cpu.fill")]
        case .performance: [("Liberar memória RAM", "memorychip.fill"),
                            ("Limpar cache de DNS", "network"),
                            ("Agentes em segundo plano", "gearshape.2.fill")]
        case .apps: [("Desinstalação completa", "xmark.app.fill"),
                     ("Restos na Biblioteca", "tray.full.fill"),
                     ("Tamanho de cada app", "scalemass.fill")]
        case .clutter: [("Arquivos grandes", "externaldrive.fill"),
                        ("Duplicados", "doc.on.doc.fill")]
        case .lens: [("Mapa visual do armazenamento", "chart.pie.fill"),
                     ("Pastas ocultas pesadas", "eye.slash.fill"),
                     ("Navegação por pastas", "folder.fill"),
                     ("Lupa do Google Drive", "icloud.fill")]
        case .cloud: [("Sugestões de arquivos sem uso", "wand.and.stars"),
                      ("Envio para o Google Drive", "icloud.and.arrow.up.fill"),
                      ("Espaço liberado só após o upload", "checkmark.shield.fill"),
                      ("Libera o que já está na nuvem", "arrow.down.circle.dotted")]
        case .compress: [("Vídeos em HEVC (H.265)", "film.fill"),
                         ("PDFs com imagens otimizadas", "doc.richtext.fill"),
                         ("Original preservado até dar certo", "checkmark.shield.fill"),
                         ("Funciona com arquivos do Drive", "icloud.fill")]
        case .routines, .organize, .backup, .phone, .download, .tools, .activity: []
        }
    }

    /// Matiz de identidade de cada módulo — usado bem de leve (paleta quase monocromática).
    var hue: Double {
        switch self {
        case .home: 0.62
        case .cleanup: 0.40
        case .performance: 0.08
        case .routines: 0.47
        case .organize: 0.12
        case .phone: 0.60
        case .backup: 0.58
        case .apps: 0.60
        case .clutter: 0.52
        case .lens: 0.72
        case .cloud: 0.57
        case .compress: 0.95
        case .download: 0.62
        case .tools: 0.66
        case .activity: 0.55
        }
    }

    /// "01", "02"… na ordem da barra lateral.
    var number: String {
        let all = Section.main + Section.quick + [.tools, .activity]
        let i = (all.firstIndex(of: self) ?? 0) + 1
        return String(format: "%02d", i)
    }

    /// Cor dominante da seção no modo "Variado".
    var tone: SectionTone {
        switch self {
        case .home, .routines, .organize, .apps, .tools, .backup, .phone, .download: .light
        case .cleanup, .lens, .cloud, .activity: .dark
        case .performance, .clutter, .compress: .navy
        }
    }

    /// Prata com um sopro de cor: botões, brilhos e detalhes.
    var accent: Color { Color(hue: hue, saturation: 0.10, brightness: 0.96) }

    /// Fundo: preto profundo → grafite, com um leve tom do módulo.
    var background: (Color, Color) {
        (Color(red: 0.02, green: 0.02, blue: 0.025),
         Color(hue: hue, saturation: 0.18, brightness: 0.14))
    }

    /// Formato do ícone de vidro (raio dos cantos; 999 = círculo).
    var heroRadius: CGFloat {
        switch self {
        case .cleanup, .lens: 999
        case .performance: 60
        default: 80
        }
    }
}

// MARK: - Estado do app

@MainActor
final class AppState: ObservableObject {
    @Published var section: Section = .home
    @Published var junk: [JunkCategory] = []
    @Published var duplicates: [DuplicateGroup] = []
    @Published var largeFiles: [FileItem] = []
    @Published var apps: [AppEntry] = []
    @Published var launchItems: [LaunchItem] = []
    @Published var selected: Set<URL> = []
    @Published var clutterTab = 0

    // Nuvem
    @Published var cloudDests: [CloudDest] = []
    @Published var cloudDest: CloudDest?
    @Published var cloudCandidates: [FileItem] = []
    @Published var cloudLocal: [FileItem] = []
    @Published var cloudJobs: [CloudJob] = []
    @Published var cloudLocalChecking = false
    var cloudPolling = false

    // Lupa: 0 = Este Mac, 1 = Google Drive
    @Published var lensSource = 0


    // Organizador de pastas
    @Published var organizer: OrganizerConfig = AppState.loadOrganizer()
    @Published var organizerPlan: [OrganizePlanItem]?
    @Published var organizerUndo: [OrganizeMove] = AppState.loadOrganizerUndo()
    @Published var organizerRunning = false
    var organizerToken = UUID()

    // Backup agendado para o Drive
    @Published var backup: BackupConfig = AppState.loadBackup()
    @Published var backupLog: [BackupEntry] = AppState.loadBackupLog()
    @Published var backupRunning = false
    @Published var backupProgress = BackupProgress()
    @Published var backupPreview: (Int, Int64)?

    // Recibos: espaço real medido no disco
    @Published var receipts: [Receipt] = AppState.loadReceipts()
    @Published var lastReceipt: Receipt?

    // Rotinas automáticas
    @Published var routines: [Routine] = AppState.loadRoutines()
    @Published var routineLog: [RoutineLog] = AppState.loadRoutineLog()
    @Published var routineRunning: Set<RoutineKind> = []
    @Published var routinePreview: [RoutineKind: [FileItem]] = [:]

    init() { startRoutineLoop(); startBackupLoop() }

    static let machineName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

    /// Pasta do Google Drive (calculada uma vez; atualizada ao analisar a Nuvem).
    var cachedDriveRoot: URL?? = nil
    var lensCache: [URL: [FileItem]] = [:]
    /// Quais itens de cada pasta são pastas navegáveis (sem pacotes nem atalhos), medidos uma vez.
    var lensDirs: [URL: Set<URL>] = [:]

    // Compressor
    @Published var compressItems: [CompressItem] = []
    @Published var compressJobs: [CompressJob] = []
    @Published var compressQuality = 0      // 0 = alta qualidade, 1 = menor tamanho (1080p)
    @Published var audioItems: [CompressItem] = []
    @Published var mp3Quality = 1          // 0 = alta, 1 = padrão, 2 = leve (128 kbps)
    @Published var compressOriginal = 0     // 0 = Lixeira, 1 = apagar de vez, 2 = manter e salvar cópia
    @Published var driveReport: DriveReport?
    @Published var driveScanning = false
    @Published var driveProgress: (Int, Int64) = (0, 0)

    @Published var scanned: Set<Section> = []
    @Published var busy: Section?
    @Published var isWorking = false
    @Published var phase = ""
    private var progressCap: Double = 0
    private var progressTicker: Task<Void, Never>?
    /// A barra de % vive num objeto próprio: só ela redesenha a cada passo, não a tela inteira.
    let meter = ScanMeter()
    var progress: Double {
        get { meter.value }
        set { meter.value = newValue }
    }
    @Published var toast: String?

    // Histórico (Atividades)
    @Published var freedTotal: Int64 = Int64(UserDefaults.standard.double(forKey: "freedTotal"))
    @Published var cleanCount: Int = UserDefaults.standard.integer(forKey: "cleanCount")
    @Published var lastClean: Date? = UserDefaults.standard.object(forKey: "lastClean") as? Date

    var isScanning: Bool { busy != nil }
    var hasScanned: Bool { scanned.contains(.home) }

    // Totais
    var junkTotal: Int64 { junk.reduce(0) { $0 + $1.total } }
    var dupWasted: Int64 { duplicates.reduce(0) { $0 + $1.wasted } }
    var dupExtraCount: Int { duplicates.reduce(0) { $0 + $1.files.count - 1 } }
    var largeTotal: Int64 { largeFiles.reduce(0) { $0 + $1.size } }

    func selectedSize(_ items: [FileItem]) -> Int64 {
        items.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size }
    }
    var selectedJunk: Int64 { selectedSize(junk.flatMap(\.items)) }
    var selectedDups: Int64 { selectedSize(duplicates.flatMap(\.files)) }
    var selectedLarge: Int64 { selectedSize(largeFiles) }

    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }
    func setAll(_ items: [FileItem], _ on: Bool) {
        for i in items { if on { selected.insert(i.url) } else { selected.remove(i.url) } }
    }

    private func defaultSelection() {
        // Duplicados e caches sensíveis ficam desmarcados: podem ser mídia de projeto ou arquivo da nuvem.
        selected = Set(junk.filter(\.preselect).flatMap { $0.items.map(\.url) })
    }

    // MARK: Análises

    // MARK: Progresso (barra com %)

    /// Começa uma barra nova: ela anda suave em direção ao teto da etapa atual.
    private func beginProgress() {
        progress = 0
        progressCap = 0
        progressTicker?.cancel()
        progressTicker = Task { @MainActor in
            while !Task.isCancelled {
                let gap = progressCap - progress
                if gap > 0.0005 { progress += gap * 0.045 }
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        }
    }

    /// Nova etapa: a barra pode chegar até `upTo` (0…1) enquanto ela roda.
    private func stage(_ upTo: Double, _ text: String) {
        progress = max(progress, progressCap)          // fecha a etapa anterior
        progressCap = upTo
        phase = text
    }

    private func endProgress() async {
        progressTicker?.cancel()
        withAnimation(.easeOut(duration: 0.3)) { progress = 1 }
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    func scan(_ s: Section) async {
        guard busy == nil else { return }
        switch s {
        case .home:
            await smartScan()
            return
        case .lens, .routines, .organize, .backup, .phone, .tools, .activity:
            return
        default: break
        }
        busy = s
        beginProgress()
        switch s {
        case .cleanup:
            stage(0.95, "Procurando caches, logs e restos…")
            junk = await Task.detached { Scanner.scanJunk() }.value
            defaultSelection()
        case .clutter:
            let tDups = Task.detached(priority: .userInitiated) { Scanner.scanDuplicates() }
            let tLarge = Task.detached(priority: .userInitiated) { Scanner.scanLargeFiles() }
            stage(0.70, "Comparando arquivos idênticos…")
            duplicates = await tDups.value
            stage(0.97, "Procurando arquivos grandes…")
            largeFiles = await tLarge.value
        case .performance:
            stage(0.95, "Verificando o que roda em segundo plano…")
            launchItems = await Task.detached { Scanner.scanLaunchItems() }.value
        case .apps:
            stage(0.97, "Medindo seus aplicativos…")
            apps = await Task.detached { Scanner.scanApps() }.value
        case .cloud:
            cachedDriveRoot = nil
            stage(0.97, "Procurando arquivos pesados e sem uso…")
            cloudDests = CloudEngine.destinations()
            if cloudDest == nil || !cloudDests.contains(cloudDest!) { cloudDest = cloudDests.first }
            cloudCandidates = await Task.detached { CloudEngine.suggestions() }.value
            // A conferência do que já está na nuvem roda em segundo plano (listar o Drive inteiro demora).
            let dests = cloudDests
            cloudLocalChecking = true
            Task {
                cloudLocal = await Task.detached { CloudEngine.localCopies(in: dests) }.value
                cloudLocalChecking = false
            }
        case .compress:
            stage(0.97, "Procurando vídeos e PDFs pesados…")
            compressItems = await CompressEngine.scan()
        default: break
        }
        await endProgress()
        busy = nil
        withAnimation(.easeInOut(duration: 0.35)) { _ = scanned.insert(s) }
    }

    func smartScan() async {
        guard busy == nil || busy == .home else { return }
        busy = .home
        beginProgress()
        // As quatro buscas rodam ao mesmo tempo, em núcleos diferentes.
        let tJunk = Task.detached(priority: .userInitiated) { Scanner.scanJunk() }
        let tDups = Task.detached(priority: .userInitiated) { Scanner.scanDuplicates() }
        let tLarge = Task.detached(priority: .userInitiated) { Scanner.scanLargeFiles() }
        let tLaunch = Task.detached(priority: .userInitiated) { Scanner.scanLaunchItems() }
        stage(0.40, "Procurando arquivos inúteis…")
        junk = await tJunk.value
        stage(0.66, "Comparando downloads duplicados…")
        duplicates = await tDups.value
        stage(0.90, "Encontrando arquivos grandes…")
        largeFiles = await tLarge.value
        stage(0.98, "Verificando itens de inicialização…")
        launchItems = await tLaunch.value
        defaultSelection()
        await endProgress()
        busy = nil
        withAnimation(.easeInOut(duration: 0.35)) { scanned.formUnion([.home, .cleanup, .clutter, .performance]) }
    }

    /// Volta o módulo para a tela de abertura.
    func reset(_ s: Section) {
        withAnimation(.easeInOut(duration: 0.3)) {
            if s == .home { scanned.removeAll() } else { scanned.remove(s) }
        }
    }

    // MARK: Ações

    func clean(junk doJunk: Bool, dups doDups: Bool) async {
        isWorking = true
        var del: [FileItem] = [], tr: [FileItem] = []
        if doJunk {
            for c in junk {
                let s = c.items.filter { selected.contains($0.url) }
                if c.removal == .delete { del += s } else { tr += s }
            }
        }
        if doDups {
            for g in duplicates {
                var pick = g.files.filter { selected.contains($0.url) }
                if pick.count == g.files.count { pick.removeFirst() }   // nunca apaga todas as cópias
                tr += pick
            }
        }
        let (d, t) = (del, tr)
        let res = await measured(doJunk ? "Limpeza" : "Duplicados") {
            await Task.detached { FS.remove(d, permanently: true) + FS.remove(t, permanently: false) }.value
        }
        forget(Set((d + t).map(\.url).filter { !res.failedPaths.contains($0.path) }))
        junk = await Task.detached { Scanner.scanJunk() }.value
        if doDups { duplicates = await Task.detached { Scanner.scanDuplicates() }.value }
        defaultSelection()
        isWorking = false
    }

    func trashLarge() async {
        isWorking = true
        let items = largeFiles.filter { selected.contains($0.url) }
        let r = await measured("Arquivos grandes") { await Task.detached { FS.remove(items, permanently: false) }.value }
        forget(Set(items.filter { !r.failedPaths.contains($0.url.path) }.map(\.url)))
        isWorking = false
    }

    /// Tira das outras telas o que já foi removido (evita escolher um arquivo que não existe mais).
    func forget(_ removed: Set<URL>) {
        guard !removed.isEmpty else { return }
        largeFiles.removeAll { removed.contains($0.url) }
        duplicates = duplicates.compactMap { g in
            let left = g.files.filter { !removed.contains($0.url) }
            return left.count > 1 ? DuplicateGroup(hash: g.hash, files: left) : nil
        }
        cloudCandidates.removeAll { removed.contains($0.url) }
        compressItems.removeAll { removed.contains($0.url) }
        selected.subtract(removed)
    }

    func uninstall(_ app: AppEntry, leftovers: [FileItem]) async {
        isWorking = true
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
            running.terminate()
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let items = [FileItem(url: app.url, size: app.size)] + leftovers
        let r = await measured("Desinstalar \(app.name)") { await Task.detached { FS.remove(items, permanently: false) }.value }
        isWorking = false
        if r.failedPaths.contains(app.url.path) {
            toast = "Não consegui remover \(app.name). Talvez precise de permissão de administrador — arraste-o para a Lixeira pelo Finder."
        } else {
            apps.removeAll { $0 == app }
        }
    }

    func removeLaunchItem(_ item: LaunchItem) async {
        let ok = await Task.detached { Scanner.unloadAndTrash(item) }.value
        if ok { launchItems.removeAll { $0.id == item.id } }
        toast = ok ? "\(item.label) não vai mais abrir na inicialização." : "Não consegui remover \(item.label)."
    }

    func runAdminTask(_ title: String, _ cmd: String) async {
        let err = await Task.detached { Scanner.runAdmin(cmd) }.value   // processo separado: a tela não trava
        toast = err == nil ? "\(title): concluído ✓" : "\(title): \(err!)"
    }

    /// Aviso rápido (sem medir o disco). As ações que liberam espaço usam `measured(...)`.
    func report(_ r: CleanResult, verb: String = "liberados") {
        var msg = "\(FS.fmt(r.freed)) \(verb) · \(r.count) itens"
        if !r.failures.isEmpty { msg += " · \(r.failures.count) não puderam ser removidos" }
        toast = msg
    }
}

// MARK: - Monitor de sistema (CPU, RAM, disco)

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memUsed: Double = 0
    @Published var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 1
    @Published var swapUsed: Int64 = 0
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    @Published var memHistory: [Double] = Array(repeating: 0, count: 40)
    @Published var swapHistory: [Double] = Array(repeating: 0, count: 40)
    @Published var pressure: Int = 1

    /// Disco abaixo de 10 GB livres.
    var diskLow: Bool { diskFree > 0 && diskFree < 10_000_000_000 }

    private var lastTicks: (Double, Double)?
    private var diskTick = 0
    nonisolated(unsafe) static let host = mach_host_self()   // uma porta só (não vaza a cada leitura)
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 1.5
    }

    var memFraction: Double { memTotal > 0 ? memUsed / memTotal : 0 }
    var diskUsed: Int64 { diskTotal - diskFree }
    var diskUsedFraction: Double { 1 - Double(diskFree) / Double(max(diskTotal, 1)) }

    func refresh() {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(SystemMonitor.host, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        if r == KERN_SUCCESS {
            let t = info.cpu_ticks
            let busy = Double(t.0) + Double(t.1) + Double(t.3)
            let total = busy + Double(t.2)
            if let last = lastTicks, total > last.1 {
                cpu = (busy - last.0) / (total - last.1)
                cpuHistory.append(cpu)
                if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }
            }
            lastTicks = (busy, total)
        }

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r2 = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(SystemMonitor.host, HOST_VM_INFO64, $0, &count)
            }
        }
        if r2 == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            memUsed = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        }

        swapUsed = Perf.swapUsed()
        pressure = Perf.pressureLevel()
        memHistory.append(memFraction); if memHistory.count > 40 { memHistory.removeFirst(memHistory.count - 40) }
        swapHistory.append(min(Double(swapUsed) / 8_000_000_000, 1)); if swapHistory.count > 40 { swapHistory.removeFirst(swapHistory.count - 40) }

        diskTick += 1
        if diskTick % 10 == 1, let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(v.volumeTotalCapacity ?? 1)
        }
    }
}


/// Valor da barra de progresso, isolado do AppState para não redesenhar o app inteiro.
@MainActor
final class ScanMeter: ObservableObject {
    @Published var value: Double = 0
}
