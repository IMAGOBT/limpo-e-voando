import SwiftUI
import AppKit

// MARK: - Baixar vídeo (Instagram, Pinterest, YouTube…) pelo link, na maior qualidade até 4K.
// Usa o yt-dlp (motor de download) e o ffmpeg (junta vídeo + áudio e converte para HEVC).
// Tudo roda no próprio Mac: o app só conversa com o site do vídeo.

enum DLTools {
    static let supportBin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Limpo e Voando/bin")

    private static func find(_ name: String) -> String? {
        let dirs = [supportBin.path, "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
    static var ytdlp: String? { find("yt-dlp") ?? find("yt-dlp_macos") }
    static var ffmpeg: String? { find("ffmpeg") }
    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Baixa o yt-dlp oficial (binário universal: Intel e chip Apple) para a pasta do app.
    static func installYtDlp() async -> String? {
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return "O GitHub não respondeu. Tente de novo." }
            try FileManager.default.createDirectory(at: supportBin, withIntermediateDirectories: true)
            let dst = supportBin.appendingPathComponent("yt-dlp")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            return nil
        } catch {
            return "Não consegui baixar o componente: \(error.localizedDescription)"
        }
    }

    /// Instala o ffmpeg pelo Homebrew (só quando o Homebrew existe).
    static func installFfmpeg() async -> String? {
        guard let brew else { return "Sem Homebrew. Instale em brew.sh e tente de novo." }
        let code = await Task.detached { () -> Int32 in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: brew)
            p.arguments = ["install", "ffmpeg"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }.value
        return code == 0 ? nil : "A instalação do ffmpeg falhou."
    }
}

enum DLStatus: Equatable {
    case queued, downloading, converting, done(URL), failed(String), cancelled
}

@MainActor
final class DLJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    @Published var title: String
    @Published var progress: Double = 0
    @Published var detail = "Na fila"
    @Published var status: DLStatus = .queued
    @Published var resolution: String = ""
    var process: Process?
    var streams = 0

    init(url: String) {
        self.url = url
        self.title = DLJob.siteName(url)
    }

    static func siteName(_ s: String) -> String {
        let h = URL(string: s)?.host?.lowercased() ?? ""
        if h.contains("youtu") { return "Vídeo do YouTube" }
        if h.contains("instagram") { return "Vídeo do Instagram" }
        if h.contains("pinterest") || h.contains("pin.it") { return "Vídeo do Pinterest" }
        if h.contains("tiktok") { return "Vídeo do TikTok" }
        return "Vídeo"
    }
}

@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()

    @Published var jobs: [DLJob] = []
    @Published var hasYtDlp = DLTools.ytdlp != nil
    @Published var hasFfmpeg = DLTools.ffmpeg != nil
    @Published var installing = false
    @Published var message: String?

    @Published var folderPath = UserDefaults.standard.string(forKey: "dl.folder")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Limpo e Voando").path {
        didSet { UserDefaults.standard.set(folderPath, forKey: "dl.folder") }
    }
    /// Converte VP9/AV1 (4K do YouTube) para HEVC, que abre no QuickTime, Premiere e Final Cut.
    @Published var compat = UserDefaults.standard.object(forKey: "dl.compat") as? Bool ?? true {
        didSet { UserDefaults.standard.set(compat, forKey: "dl.compat") }
    }
    /// 0 = nenhum, 1 = Safari, 2 = Chrome (para vídeos que pedem login, como alguns do Instagram).
    @Published var cookies = UserDefaults.standard.integer(forKey: "dl.cookies") {
        didSet { UserDefaults.standard.set(cookies, forKey: "dl.cookies") }
    }

    private var running = false

    func refreshTools() {
        hasYtDlp = DLTools.ytdlp != nil
        hasFfmpeg = DLTools.ffmpeg != nil
    }

    func installMissing() async {
        installing = true
        defer { installing = false; refreshTools() }
        if DLTools.ytdlp == nil, let err = await DLTools.installYtDlp() { message = err; return }
        if DLTools.ffmpeg == nil, DLTools.brew != nil, let err = await DLTools.installFfmpeg() { message = err; return }
    }

    /// Aceita um ou vários links (um por linha ou separados por espaço).
    func add(_ text: String) {
        let links = text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { s in
                guard let u = URL(string: s), let sc = u.scheme?.lowercased() else { return false }
                return (sc == "https" || sc == "http") && u.host != nil
            }
        guard !links.isEmpty else { message = "Cole um link que comece com https://"; return }
        for l in links { jobs.insert(DLJob(url: l), at: 0) }
        pump()
    }

    func cancel(_ job: DLJob) {
        switch job.status {
        case .queued, .downloading, .converting:
            job.status = .cancelled
            job.detail = "Cancelado"
            job.process?.terminate()
        default: break
        }
    }

    func remove(_ job: DLJob) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll {
            switch $0.status { case .done, .failed, .cancelled: true; default: false }
        }
    }

    /// Um download por vez: o Mac (e a internet) ficam leves.
    private func pump() {
        guard !running, let job = jobs.last(where: { $0.status == .queued }) else { return }
        running = true
        Task {
            await run(job)
            running = false
            pump()
        }
    }

    // MARK: Execução

    private func run(_ job: DLJob) async {
        guard let ytdlp = DLTools.ytdlp else {
            job.status = .failed("Falta o componente de download. Toque em \"Instalar componentes\"."); return
        }
        let folder = URL(fileURLWithPath: folderPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = FileManager.default.temporaryDirectory.appendingPathComponent("lev-\(job.id.uuidString).txt")
        defer { try? FileManager.default.removeItem(at: info) }

        var args = [
            "--no-playlist", "--newline", "--no-mtime", "--restrict-filenames", "--no-part",
            // maior resolução até 4K, depois mais quadros por segundo
            "-f", "bv*+ba/b", "-S", "res:2160,fps,hdr:sdr,vcodec:h264",
            "--merge-output-format", "mp4",
            "-o", folder.path + "/%(title).90B [%(id)s].%(ext)s",
            "--progress-template", "download:LEVP %(progress._percent_str)s %(progress._speed_str)s %(progress._eta_str)s",
            "--print-to-file", "after_move:%(filepath)s\t%(height)s\t%(vcodec)s\t%(duration)s\t%(title)s", info.path,
        ]
        if let ff = DLTools.ffmpeg { args += ["--ffmpeg-location", ff] }
        switch cookies {
        case 1: args += ["--cookies-from-browser", "safari"]
        case 2: args += ["--cookies-from-browser", "chrome"]
        default: break
        }
        args.append(job.url)

        job.status = .downloading
        job.detail = "Conectando…"
        let (code, errText) = await runProcess(ytdlp, args, job: job) { [weak job] line in
            guard let job else { return }
            if line.hasPrefix("[download] Destination:") {
                job.streams += 1
                let name = URL(fileURLWithPath: String(line.dropFirst(24))).deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: #"\.f\d+$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #" ?\[[^\]]+\]$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "_", with: " ")
                if !name.isEmpty { job.title = name }
            } else if line.hasPrefix("LEVP ") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, let pct = Double(parts[1].replacingOccurrences(of: "%", with: "")) {
                    // 1º arquivo (vídeo) = 0–85%, 2º (áudio) = 85–96%
                    let base = job.streams <= 1 ? 0.0 : 0.85
                    let span = job.streams <= 1 ? 0.85 : 0.11
                    job.progress = max(job.progress, base + span * pct / 100)
                    let speed = parts.count > 2 ? String(parts[2]) : ""
                    let eta = parts.count > 3 ? String(parts[3]) : ""
                    job.detail = job.streams <= 1 ? "Baixando vídeo · \(speed) · falta \(eta)" : "Baixando áudio · \(speed)"
                }
            } else if line.hasPrefix("[Merger]") {
                job.progress = max(job.progress, 0.96)
                job.detail = "Juntando vídeo e áudio…"
            }
        }

        if case .cancelled = job.status { return }
        if job.process?.terminationReason == .uncaughtSignal { job.status = .cancelled; job.detail = "Cancelado"; return }
        guard code == 0, let line = try? String(contentsOf: info, encoding: .utf8)
            .split(separator: "\n").last.map(String.init) else {
            job.status = .failed(friendly(errText))
            job.detail = "Não deu certo"
            return
        }
        let f = line.components(separatedBy: "\t")
        var file = URL(fileURLWithPath: f[0])
        let height = Int(f[safe: 1] ?? "") ?? 0
        let vcodec = (f[safe: 2] ?? "").lowercased()
        let duration = Double(f[safe: 3] ?? "") ?? 0
        if let t = f[safe: 4], !t.isEmpty { job.title = t }
        job.resolution = height >= 2160 ? "4K" : height >= 1440 ? "2K" : height > 0 ? "\(height)p" : ""

        // VP9/AV1 não abrem no QuickTime/Premiere: converte para HEVC (aceleração da placa de vídeo).
        let playable = vcodec.hasPrefix("avc") || vcodec.hasPrefix("h264") || vcodec.hasPrefix("hvc") || vcodec.hasPrefix("hev") || vcodec.hasPrefix("h265")
        if compat, !playable, !vcodec.isEmpty, vcodec != "none", let ff = DLTools.ffmpeg {
            job.status = .converting
            job.progress = 0.97
            job.detail = "Deixando compatível com o Mac (HEVC)…"
            if let out = await convert(file, ffmpeg: ff, height: height, duration: duration, job: job) { file = out }
        }
        if case .cancelled = job.status { return }
        job.progress = 1
        job.detail = [job.resolution, FS.fmt(FS.size(of: file))].filter { !$0.isEmpty }.joined(separator: " · ")
        job.status = .done(file)
    }

    /// Converte para HEVC (ou H.264 em Macs sem HEVC na placa de vídeo). Mantém o original se falhar.
    private func convert(_ src: URL, ffmpeg: String, height: Int, duration: Double, job: DLJob) async -> URL? {
        let dst = src.deletingPathExtension().appendingPathExtension("hevc.mp4")
        let mbps = height >= 2160 ? 45 : height >= 1440 ? 24 : height >= 1080 ? 12 : 6
        let encoders: [[String]] = [
            ["-c:v", "hevc_videotoolbox", "-b:v", "\(mbps)M", "-tag:v", "hvc1"],
            ["-c:v", "h264_videotoolbox", "-b:v", "\(mbps + mbps / 2)M"],
        ]
        for enc in encoders {
            try? FileManager.default.removeItem(at: dst)
            let args = ["-hide_banner", "-y", "-nostats", "-progress", "pipe:1", "-i", src.path]
                + enc + ["-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", dst.path]
            let (code, _) = await runProcess(ffmpeg, args, job: job) { [weak job] line in
                guard let job, duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                      let us = Double(line.split(separator: "=").last ?? "") else { return }
                let p = min(1, us / 1_000_000 / duration)
                job.progress = 0.97 + 0.03 * p
                job.detail = "Deixando compatível com o Mac · \(Int(p * 100))%"
            }
            if case .cancelled = job.status { try? FileManager.default.removeItem(at: dst); return nil }
            if code == 0, FileManager.default.fileExists(atPath: dst.path) {
                let final = src.deletingPathExtension().appendingPathExtension("mp4")
                _ = try? FileManager.default.replaceItemAt(final, withItemAt: dst)
                if src != final { try? FileManager.default.removeItem(at: src) }
                return final
            }
        }
        try? FileManager.default.removeItem(at: dst)
        return nil
    }

    /// Roda um programa fora da thread principal e entrega cada linha (no máx. ~8 atualizações por segundo).
    private func runProcess(_ exe: String, _ args: [String], job: DLJob,
                            onLine: @escaping @MainActor (String) -> Void) async -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        job.process = p

        let errBox = LineBox()
        let outBox = LineBox()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let lines = outBox.feed(d)
            // linhas de progresso chegam em rajada: manda só a mais recente, no máx. ~8 vezes por segundo
            let isTick: (String) -> Bool = { $0.hasPrefix("LEVP ") || $0.hasPrefix("out_time") }
            var send = lines.filter { !isTick($0) }
            if let tick = lines.last(where: isTick) {
                if outBox.shouldFlush() { send.append(tick) }
            }
            guard !send.isEmpty else { return }
            Task { @MainActor in for l in send { onLine(l) } }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            errBox.append(d)
        }

        let code: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch {
                p.terminationHandler = nil
                cont.resume(returning: -1)
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            for l in rest.split(separator: "\n") { onLine(String(l)) }
        }
        return (code, errBox.text)
    }

    private func friendly(_ err: String) -> String {
        let e = err.lowercased()
        if e.contains("login") || e.contains("cookies") || e.contains("rate-limit") || e.contains("private") {
            return "Esse vídeo pede login. Em \"Ajustes\", escolha usar o login do Safari ou do Chrome e tente de novo."
        }
        if e.contains("unsupported url") { return "Esse site ou link não é suportado." }
        if e.contains("unable to download") || e.contains("network") || e.contains("timed out") {
            return "Falha de conexão. Confira a internet e tente de novo."
        }
        if e.contains("not available") || e.contains("removed") || e.contains("404") { return "O vídeo não está mais disponível." }
        let last = err.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init) ?? ""
        return last.isEmpty ? "Não consegui baixar esse link." : last.replacingOccurrences(of: "ERROR: ", with: "")
    }
}

/// Junta pedaços de texto em linhas, de forma segura entre threads.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var all = Data()
    private var last = Date.distantPast

    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var lines: [String] = []
        while let r = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let chunk = buffer[buffer.startIndex..<r]
            buffer.removeSubrange(buffer.startIndex...r)
            if let s = String(data: chunk, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        return lines
    }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if all.count < 200_000 { all.append(d) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: all, encoding: .utf8) ?? ""
    }
    func shouldFlush() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) > 0.12 { last = now; return true }
        return false
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Tela

struct DownloadView: View {
    @ObservedObject private var center = DownloadCenter.shared
    @State private var link = ""
    @State private var showSettings = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !center.hasYtDlp || !center.hasFfmpeg { setupCard }

            // Campo do link
            GlassCard(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(Color.ink.opacity(0.6))
                        TextField("Cole o link do Instagram, Pinterest ou YouTube", text: $link)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .focused($focused)
                            .onSubmit(start)
                        if link.isEmpty {
                            Button { paste() } label: {
                                Label("Colar", systemImage: "doc.on.clipboard").font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.blue)
                        }
                        PillButton(title: "Baixar", icon: "arrow.down", enabled: center.hasYtDlp && !link.isEmpty) { start() }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ink.opacity(0.05)))

                    HStack(spacing: 14) {
                        Label("Sempre na maior qualidade, até 4K", systemImage: "4k.tv").font(.system(size: 12))
                        Spacer()
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: center.folderPath)) } label: {
                            Label(URL(fileURLWithPath: center.folderPath).lastPathComponent, systemImage: "folder")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        Button { showSettings.toggle() } label: {
                            Label("Ajustes", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
                    }
                    .foregroundStyle(Color.ink.opacity(0.76))
                }
            }

            // Fila
            if center.jobs.isEmpty {
                EmptyHint()
            } else {
                HStack {
                    Text("Downloads").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.8))
                    Spacer()
                    Button("Limpar concluídos") { center.clearFinished() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.7))
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(center.jobs) { JobRow(job: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            center.refreshTools()
            focused = true
            // link copiado agora há pouco? já deixa pronto
            if link.isEmpty, let s = NSPasteboard.general.string(forType: .string), looksLikeVideo(s) { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        .alert(center.message ?? "", isPresented: Binding(get: { center.message != nil }, set: { if !$0 { center.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Section.download.number).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Rectangle().fill(Color.ink.opacity(0.4)).frame(width: 22, height: 0.8)
                Text("BAIXAR VÍDEO").font(.system(size: 11, weight: .semibold)).tracking(2.2)
            }
            .foregroundStyle(Color.ink.opacity(0.74))
            Text("Cole o link. O vídeo chega no Mac na maior qualidade.")
                .font(.system(size: 26, weight: .light))
        }
    }

    private var setupCard: some View {
        GlassCard(padding: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "shippingbox.fill", tint: Theme.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Falta instalar os componentes de download").font(.system(size: 14, weight: .semibold))
                    Text(setupText).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.74))
                }
                Spacer()
                if center.installing {
                    ProgressView().controlSize(.small)
                } else {
                    PillButton(title: "Instalar componentes", icon: "arrow.down.circle") {
                        Task { await center.installMissing() }
                    }
                }
            }
        }
    }

    private var setupText: String {
        var s: [String] = []
        if !center.hasYtDlp { s.append("motor de download (yt-dlp, oficial do GitHub)") }
        if !center.hasFfmpeg {
            s.append(DLTools.brew != nil ? "ffmpeg (pelo Homebrew), para o 4K" : "ffmpeg: instale o Homebrew em brew.sh para liberar o 4K")
        }
        return s.joined(separator: " · ")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajustes do download").font(.system(size: 13, weight: .semibold))
            Toggle("Converter para HEVC (abre no QuickTime e no Premiere)", isOn: $center.compat)
                .toggleStyle(.switch).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text("Vídeos que pedem login (ex.: alguns do Instagram)").font(.system(size: 12))
                Picker("", selection: $center.cookies) {
                    Text("Sem login").tag(0)
                    Text("Usar login do Safari").tag(1)
                    Text("Usar login do Chrome").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("O app só lê o login para pedir o vídeo ao site. Nada é enviado para outro lugar.")
                    .font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.7))
            }
            HStack {
                Text("Salvar em").font(.system(size: 12))
                Text(center.folderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Trocar…") { chooseFolder() }
            }
            Text("Baixe só vídeos que você tem direito de usar.").font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.7))
        }
        .padding(18)
        .frame(width: 420)
    }

    private func start() {
        guard !link.isEmpty else { return }
        center.add(link)
        link = ""
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func looksLikeVideo(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http") && ["youtu", "instagram.com", "pinterest", "pin.it", "tiktok.com", "vimeo.com"].contains { t.contains($0) }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Escolher"
        if p.runModal() == .OK, let u = p.url { center.folderPath = u.path }
    }
}

private struct EmptyHint: View {
    var body: some View {
        HStack(spacing: 22) {
            ForEach([("play.rectangle.fill", "YouTube", "Até 4K, com áudio"),
                     ("camera.fill", "Instagram", "Reels e posts"),
                     ("pin.fill", "Pinterest", "Vídeos dos pins")], id: \.1) { icon, name, sub in
                HStack(spacing: 12) {
                    IconTile(symbol: icon, tint: Theme.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        Text(sub).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.74))
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

private struct JobRow: View {
    @ObservedObject var job: DLJob
    @ObservedObject private var center = DownloadCenter.shared

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 14) {
                icon.frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !job.resolution.isEmpty {
                            Text(job.resolution).font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.blue.opacity(0.15))).foregroundStyle(Theme.blue)
                        }
                    }
                    if isActive {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.ink.opacity(0.1))
                                Capsule().fill(Theme.blue).frame(width: max(4, g.size.width * job.progress))
                                    .animation(.easeOut(duration: 0.25), value: job.progress)
                            }
                        }
                        .frame(height: 4)
                    }
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(subtitleColor).lineLimit(2)
                }
                Spacer(minLength: 8)
                actions
            }
        }
    }

    private var isActive: Bool {
        switch job.status { case .downloading, .converting, .queued: true; default: false }
    }

    private var subtitle: String {
        switch job.status {
        case .failed(let m): m
        default: job.detail
        }
    }

    private var subtitleColor: Color {
        switch job.status {
        case .failed: Theme.red
        case .done: Theme.green
        default: Color.ink.opacity(0.74)
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.red)
        case .cancelled: Image(systemName: "xmark.circle").font(.system(size: 22)).foregroundStyle(Color.ink.opacity(0.5))
        case .queued: Image(systemName: "clock").font(.system(size: 20)).foregroundStyle(Color.ink.opacity(0.6))
        case .downloading, .converting: ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.status {
        case .done(let url):
            HStack(spacing: 14) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "play.fill") }
                    .help("Abrir")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Mostrar no Finder")
            }
            .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.8))
        case .failed, .cancelled:
            HStack(spacing: 14) {
                Button { center.remove(job); center.add(job.url) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Tentar de novo")
                Button { center.remove(job) } label: { Image(systemName: "xmark") }.help("Tirar da lista")
            }
            .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.8))
        default:
            Button { center.cancel(job) } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.8)).help("Cancelar")
        }
    }
}
