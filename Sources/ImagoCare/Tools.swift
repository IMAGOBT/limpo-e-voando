import SwiftUI
import AppKit

// MARK: - Ferramentas

struct Tool: Identifiable {
    var id: String { title }
    let title: String
    let text: String
    let symbol: String
    let tint: Color
    var status: String? = nil
    var isNew = false
    var button = "Analisar"
    let run: () -> Void

    /// 0 = Limpeza, 1 = Desempenho, 2 = Processos rápidos
    var group: Int {
        switch title {
        case "Itens em segundo plano", "Tarefas de manutenção", "Itens de início", "Permissões de apps",
             "Preparar para exportar", "Apps pesados agora": return 1
        case "Modo de limpeza da tela", "Mover para a nuvem", "Backup para o Drive", "Celular → Drive", "Compressor de vídeos e PDFs", "Lupa do Drive": return 2
        default: return 0
        }
    }
}

struct ToolsView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var trashSize: Int64?? = .none
    @State private var snapshots: Int?
    @State private var confirmTrash = false
    @State private var confirmSnapshots = false

    private func open(_ s: Section, tab: Int? = nil) {
        if let tab { state.clutterTab = tab }
        withAnimation(.easeInOut(duration: 0.3)) { state.section = s }
    }

    private func openSettings(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private var tools: [Tool] {
        let trashStatus: String? = {
            switch trashSize {
            case .some(.some(let v)): return v > 0 ? "\(FS.fmt(v)) na Lixeira" : "Lixeira vazia"
            case .some(.none): return nil
            case .none: return "Medindo…"
            }
        }()
        return [
            Tool(title: "Modo de limpeza da tela", text: "Bloqueia o teclado e apaga a tela para você passar o pano sem apertar nada sem querer.",
                 symbol: "sparkles.tv.fill", tint: Color(red: 1, green: 0.45, blue: 0.75), isNew: true, button: "Abrir") {
                ScreenCleaner.start()
            },
            Tool(title: "Rotinas automáticas", text: "Instaladores, capturas, gerações de IA e Downloads antigos saem sozinhos, do jeito que você configurar.",
                 symbol: "clock.arrow.2.circlepath", tint: Section.routines.accent, isNew: true, button: "Configurar") { open(.routines) },
            Tool(title: "Celular → Drive · bônus", text: "Em teste. Conecte o iPhone (ou Android) no cabo: fotos e vídeos vão para o Drive por data, renomeados. Depois, libere o celular.",
                 symbol: "iphone", tint: Theme.blue, isNew: true, button: "Abrir") { open(.phone) },
            Tool(title: "Organizar pastas", text: "Separa o Downloads (ou outra pasta) por tipo ou por mês. Só move, nunca apaga, e dá para desfazer.",
                 symbol: "tray.2.fill", tint: Theme.blue, isNew: true, button: "Abrir") { open(.organize) },
            Tool(title: "Backup para o Drive", text: "Escolha pastas, dia e horário: o que mudou sobe sozinho para o Google Drive.",
                 symbol: "externaldrive.badge.icloud", tint: Section.cloud.accent, isNew: true, button: "Configurar") { open(.backup) },
            Tool(title: "Gerações de IA", text: "Imagens e vídeos de Higgsfield, Midjourney, ChatGPT e afins esquecidos no Downloads.",
                 symbol: "wand.and.stars", tint: Section.cleanup.accent, isNew: true) { open(.cleanup) },
            Tool(title: "Previews do Premiere", text: "Renders de pré-visualização e autosaves antigos espalhados nas pastas dos projetos.",
                 symbol: "film.stack.fill", tint: Section.cleanup.accent, isNew: true) { open(.cleanup) },
            Tool(title: "Apps pesados agora", text: "Veja quem está comendo RAM e CPU neste momento e encerre com um clique.",
                 symbol: "gauge.with.dots.needle.67percent", tint: Section.performance.accent, isNew: true) { open(.performance) },
            Tool(title: "Preparar para exportar", text: "Antes de renderizar: confere o espaço, fecha apps pesados e libera memória.",
                 symbol: "square.and.arrow.up.on.square.fill", tint: Section.performance.accent, isNew: true) {
                state.scanned.insert(.performance)
                open(.performance)
            },
            Tool(title: "Mover para a nuvem", text: "Mande vídeos e arquivos pesados para o Google Drive e libere o espaço no Mac.",
                 symbol: "icloud.and.arrow.up.fill", tint: Section.cloud.accent, isNew: true) { open(.cloud) },
            Tool(title: "Compressor de vídeos e PDFs", text: "Converte vídeos para HEVC e enxuga PDFs pesados. O original só sai quando dá certo.",
                 symbol: "arrow.down.right.and.arrow.up.left", tint: Section.compress.accent, isNew: true) { open(.compress) },
            Tool(title: "Lupa do Drive", text: "Veja o que ocupa o seu Google Drive: pastas, arquivos grandes, antigos e duplicados.",
                 symbol: "icloud.fill", tint: Section.cloud.accent, isNew: true) {
                state.lensSource = 1
                state.scanned.insert(.lens)
                open(.lens)
            },
            Tool(title: "Acúmulos de IA", text: "Modelos baixados, caches e registros de ferramentas de IA e de desenvolvimento.",
                 symbol: "cpu.fill", tint: Section.cleanup.accent, isNew: true) { open(.cleanup) },
            Tool(title: "Cache de mídia Adobe", text: "Arquivos de cache do Premiere e After Effects que eles recriam sozinhos.",
                 symbol: "film.fill", tint: Section.cleanup.accent) { open(.cleanup) },
            Tool(title: "Detritos do sistema", text: "Caches de apps, logs e instaladores esquecidos que só ocupam espaço.",
                 symbol: "bubbles.and.sparkles.fill", tint: Section.cleanup.accent) { open(.cleanup) },
            Tool(title: "Anexos do Mail", text: "Cópias locais de anexos que você abriu no Mail. Continuam guardadas no servidor.",
                 symbol: "envelope.fill", tint: Color(red: 0.35, green: 0.62, blue: 1)) { open(.cleanup) },
            Tool(title: "Lixeira", text: "Esvazie de vez a Lixeira do Mac. Isso não pode ser desfeito.",
                 symbol: "trash.fill", tint: Color(red: 0.35, green: 0.80, blue: 0.40), status: trashStatus, button: "Esvaziar") {
                confirmTrash = true
            },
            Tool(title: "Capturas do Time Machine", text: "Remove as cópias locais que o Time Machine guarda no disco, sem afetar os backups.",
                 symbol: "clock.arrow.circlepath", tint: Theme.warm,
                 status: snapshots.map { $0 == 0 ? "Nenhuma captura local" : "\($0) capturas locais" } ?? "Verificando…",
                 button: "Remover") {
                confirmSnapshots = true
            },
            Tool(title: "Desinstalador", text: "Remova aplicativos por completo, com todos os arquivos relacionados.",
                 symbol: "xmark.app.fill", tint: Section.apps.accent) { open(.apps) },
            Tool(title: "Arquivos grandes", text: "Encontre e remova arquivos pesados que você nem lembra que tem.",
                 symbol: "externaldrive.fill", tint: Section.clutter.accent) { open(.clutter, tab: 0) },
            Tool(title: "Duplicados", text: "Arquivos idênticos espalhados entre Downloads e a Mesa.",
                 symbol: "doc.on.doc.fill", tint: Section.clutter.accent) { open(.clutter, tab: 1) },
            Tool(title: "Lupa de espaço", text: "Veja num mapa as pastas que mais ocupam o disco.",
                 symbol: "circle.dashed.inset.filled", tint: Section.lens.accent) { open(.lens) },
            Tool(title: "Itens em segundo plano", text: "Agentes e processos que rodam escondidos desde que o Mac liga.",
                 symbol: "gearshape.2.fill", tint: Section.performance.accent) { open(.performance) },
            Tool(title: "Tarefas de manutenção", text: "Liberar memória RAM e limpar o cache de DNS.",
                 symbol: "wrench.and.screwdriver.fill", tint: Section.performance.accent) { open(.performance) },
            Tool(title: "Itens de início", text: "Escolha quais apps abrem sozinhos quando você liga o Mac.",
                 symbol: "power", tint: Section.performance.accent, button: "Abrir") {
                openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            },
            Tool(title: "Permissões de apps", text: "Revise quem acessa câmera, microfone, tela, arquivos e mais.",
                 symbol: "lock.shield.fill", tint: Color(red: 1, green: 0.45, blue: 0.75), button: "Abrir") {
                openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy")
            },
        ]
    }

    private var filtered: [Tool] {
        query.isEmpty ? tools : tools.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .lastTextBaseline) {
                Text("Ferramentas").font(.system(size: 44, weight: .thin))
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.ink.opacity(0.74))
                    TextField("Buscar…", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(width: 230)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ink.opacity(0.18)))
            }
            .padding(.top, 36).padding(.horizontal, 40)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([(0, "Limpeza", "bubbles.and.sparkles.fill"), (1, "Desempenho", "bolt.fill"),
                             (2, "Processos rápidos", "hare.fill")], id: \.0) { g in
                        let items = filtered.filter { $0.group == g.0 }
                        if !items.isEmpty {
                            Label(g.1, systemImage: g.2)
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.85))
                                .padding(.top, g.0 == 0 ? 0 : 14)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 18) {
                                ForEach(items) { ToolCard(tool: $0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 40).padding(.top, 10).padding(.bottom, 30)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .task {
            trashSize = .some(await Task.detached { Extras.trashSize() }.value)
            snapshots = await Task.detached { Extras.localSnapshots() }.value
        }
        .confirmationDialog("Esvaziar a Lixeira?", isPresented: $confirmTrash) {
            Button("Esvaziar", role: .destructive) {
                Task {
                    await state.emptyTrashMeasured()
                    trashSize = .some(await Task.detached { Extras.trashSize() }.value)
                }
            }
        } message: {
            Text("Tudo que está na Lixeira será apagado para sempre. O macOS pode pedir permissão para o Limpo e Voando controlar o Finder.")
        }
        .confirmationDialog("Remover capturas locais do Time Machine?", isPresented: $confirmSnapshots) {
            Button("Remover", role: .destructive) {
                Task {
                    await state.runAdminTask("Capturas do Time Machine", "/usr/bin/tmutil deletelocalsnapshots /")
                    snapshots = await Task.detached { Extras.localSnapshots() }.value
                }
            }
        } message: {
            Text("Seus backups no disco externo continuam intactos. O macOS vai pedir sua senha de administrador.")
        }
    }
}

struct ToolCard: View {
    let tool: Tool
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            GlassHero(symbol: tool.symbol, tint: tool.tint, radius: 60, size: 52, animated: false)
                .padding(.bottom, 18)
            Text(tool.title).font(.system(size: 18, weight: .semibold))
            Text(tool.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 16)
            HStack {
                if let s = tool.status {
                    Text(s).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink.opacity(0.75))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.ink.opacity(0.1)))
                }
                Spacer()
                PillButton(title: tool.button, action: tool.run)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(shape.fill(LinearGradient(colors: [Color.ink.opacity(hover ? 0.08 : 0.05), Color.ink.opacity(0.02)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(shape.strokeBorder(Color.ink.opacity(hover ? 0.28 : 0.14)))
        .overlay(alignment: .topTrailing) {
            if tool.isNew {
                Text("Novo").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(tool.tint))
                    .padding(16)
            }
        }
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Modo de limpeza da tela

/// Janela que cobre a tela e engole o teclado enquanto você limpa.
final class KeyEatingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}

@MainActor
enum ScreenCleaner {
    private static var windows: [NSWindow] = []

    static func start() {
        guard windows.isEmpty else { return }
        let mainFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame
        for screen in NSScreen.screens {
            let w = KeyEatingWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.isOpaque = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: ScreenCleanView(isMain: screen.frame == mainFrame) { stop() }.environment(\.colorScheme, .dark))
            w.setFrame(screen.frame, display: true)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
    }

    static func stop() {
        NSApp.presentationOptions = []
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

struct ScreenCleanView: View {
    let isMain: Bool
    let onExit: () -> Void
    @State private var holding = false

    var body: some View {
        ZStack {
            Color.black
            if isMain {
                VStack(spacing: 22) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 40)).foregroundStyle(Color.ink.opacity(0.35))
                    Text("Teclado bloqueado. Pode limpar a tela e o teclado.")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Color.ink.opacity(0.74))
                    Text("Para sair, segure o botão abaixo por 2 segundos.")
                        .font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.3))
                    ZStack {
                        Circle().stroke(Color.ink.opacity(0.15), lineWidth: 3)
                        Circle().trim(from: 0, to: holding ? 1 : 0)
                            .stroke(Color.ink.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(holding ? .linear(duration: 2) : .easeOut(duration: 0.2), value: holding)
                        Text("Sair").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.74))
                    }
                    .frame(width: 84, height: 84)
                    .contentShape(Circle())
                    .onLongPressGesture(minimumDuration: 2, pressing: { holding = $0 }, perform: onExit)
                    .padding(.top, 10)
                }
            }
        }
        .ignoresSafeArea()
    }
}
