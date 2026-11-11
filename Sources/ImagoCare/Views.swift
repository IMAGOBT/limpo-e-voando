import SwiftUI
import AppKit

// MARK: - Cuidado inteligente

struct HomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @State private var confirm = false

    var body: some View {
        if state.hasScanned { results } else { ModuleIntro(section: .home) }
    }

    private var junkCheck: Int {
        let pre = state.junk.filter(\.preselect).flatMap(\.items)
        let sel = pre.filter { state.selected.contains($0.url) }.count
        return sel == 0 ? 0 : sel == pre.count ? 1 : 2
    }

    private var results: some View {
        VStack(spacing: 0) {
            TopBar(section: .home)
            Text("Tudo pronto. Veja o que encontrei:")
                .font(.system(size: 34, weight: .light))
                .padding(.top, 22).padding(.bottom, 26)
            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    HomeCard(section: .cleanup, style: .black, value: "\(FS.fmt(state.junkTotal)) de lixo", caption: "para limpar",
                             check: junkCheck, onCheck: {
                                 let pre = state.junk.filter(\.preselect).flatMap(\.items)
                                 state.setAll(pre, junkCheck != 1)
                             }) { state.section = .cleanup }
                    HomeCard(section: .performance, style: .white, value: "\(state.launchItems.count) itens",
                             caption: "rodando na inicialização") { state.section = .performance }
                    HomeCard(section: .lens, style: .navy, value: "\(FS.fmt(monitor.diskFree)) livres",
                             caption: "de \(FS.fmt(monitor.diskTotal)) no disco") { state.section = .lens }
                }
                HStack(spacing: 18) {
                    HomeCard(section: .apps, style: .navy, value: "Remova apps por inteiro", caption: "sem deixar restos") { state.section = .apps }
                    HomeCard(section: .clutter, style: .black,
                             value: "\(state.dupExtraCount) duplicados · \(state.largeFiles.count) grandes",
                             caption: "para revisar com calma") { state.section = .clutter }
                }
            }
            Spacer(minLength: 12)
            RoundAction(title: "Executar", subtitle: FS.fmt(state.selectedJunk + state.selectedDups),
                        tint: Section.home.accent, busy: state.isWorking,
                        enabled: state.selectedJunk + state.selectedDups > 0) { confirm = true }
        }
        .confirmationDialog("Limpar \(FS.fmt(state.selectedJunk + state.selectedDups))?", isPresented: $confirm) {
            Button("Limpar", role: .destructive) { Task { await state.clean(junk: true, dups: true) } }
        } message: {
            Text("Caches e logs são apagados (os apps recriam o que precisarem). Instaladores e duplicados marcados vão para a Lixeira.")
        }
    }
}

/// Estilo do quadro: preto, branco ou cinza (inspirado em Tesla/Apple).
enum CardStyle {
    case black, white, navy
    var scheme: ColorScheme { self == .white ? .light : .dark }
    var fill: [Color] {
        switch self {
        case .black: [Color(white: 0.09), Color(white: 0.09)]
        case .white: [Color.white, Color.white]
        case .navy: [Palette.navyCard, Palette.navyCard]
        }
    }
    var stroke: Color { self == .white ? .black.opacity(0.08) : .white.opacity(0.12) }
}

struct HomeCard: View {
    let section: Section
    var style: CardStyle = .white
    let value: String
    let caption: String
    var check: Int? = nil
    var onCheck: (() -> Void)? = nil
    let onReview: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let check { CheckBox(state: check) { onCheck?() } }
                Text(section.title.uppercased())
                    .font(.system(size: 11.5, weight: .semibold)).tracking(1.8)
                    .foregroundStyle(Color.ink.opacity(0.75))
            }
            Spacer(minLength: 30)
            Text(value)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.ink)
                .lineLimit(2).minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.ink.opacity(0.12)).frame(height: 0.7).padding(.vertical, 12)
            HStack(alignment: .center) {
                Text(caption).font(.system(size: 14)).foregroundStyle(Color.ink.opacity(0.74))
                Spacer()
                Text("Revisar").font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .offset(x: hover ? 3 : 0)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 240)
        .background(alignment: .topTrailing) {
            GlassHero(symbol: section.heroSymbol, tint: section.accent, radius: section.heroRadius, size: 140, animated: false)
                .offset(x: 34, y: -30)
                .opacity(0.95)
        }
        .background(shape.fill(LinearGradient(colors: style.fill, startPoint: .topLeading, endPoint: .bottomTrailing)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(style.stroke, lineWidth: 0.7))
        .shadow(color: .black.opacity(hover ? 0.18 : 0.08), radius: hover ? 22 : 12, y: hover ? 10 : 5)
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hover)
        .environment(\.colorScheme, style.scheme)
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture(perform: onReview)
    }
}

// MARK: - Limpeza

struct CleanupView: View {
    @EnvironmentObject var state: AppState
    @State private var expanded: Set<String> = []
    @State private var confirm = false

    var body: some View {
        if state.scanned.contains(.cleanup) { results } else { ModuleIntro(section: .cleanup) }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 18) {
            TopBar(section: .cleanup)
            Text(state.junk.isEmpty ? "Nada para limpar por aqui." : "\(FS.fmt(state.junkTotal)) que dá para tirar do caminho")
                .font(.system(size: 30, weight: .light))
            if state.junk.isEmpty {
                EmptyState(icon: "checkmark.seal.fill", title: "Tudo limpo", text: "Seu Mac está sem lixo por enquanto.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(state.junk) { cat in category(cat) }
                    }
                }
            }
            ActionDock(section: .cleanup, label: "Selecionado: \(FS.fmt(state.selectedJunk))", button: "Limpar",
                       enabled: state.selectedJunk > 0) { confirm = true }
        }
        .confirmationDialog("Limpar \(FS.fmt(state.selectedJunk))?", isPresented: $confirm) {
            Button("Limpar", role: .destructive) { Task { await state.clean(junk: true, dups: false) } }
        } message: {
            Text("Dica: feche os apps antes. Caches e logs são apagados; instaladores vão para a Lixeira.")
        }
    }

    private func category(_ cat: JunkCategory) -> some View {
        let sel = cat.items.filter { state.selected.contains($0.url) }.count
        return GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    CheckBox(state: sel == 0 ? 0 : sel == cat.items.count ? 1 : 2) {
                        state.setAll(cat.items, sel != cat.items.count)
                    }
                    IconTile(symbol: cat.icon, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cat.name).font(.headline)
                        Text(cat.detail).font(.caption).foregroundStyle(Color.ink.opacity(0.76))
                    }
                    Spacer()
                    Text(FS.fmt(cat.total)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expanded.contains(cat.id) { expanded.remove(cat.id) } else { expanded.insert(cat.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded.contains(cat.id) ? 180 : 0))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.ink.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                if expanded.contains(cat.id) {
                    Divider().overlay(Color.ink.opacity(0.15)).padding(.vertical, 4)
                    LazyVStack(spacing: 0) { ForEach(cat.items.prefix(300)) { ItemRow(item: $0) } }
                }
            }
        }
    }
}

// MARK: - Acúmulos (arquivos grandes + duplicados)

struct ClutterView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmLarge = false
    @State private var confirmDups = false

    var body: some View {
        if state.scanned.contains(.clutter) { results } else { ModuleIntro(section: .clutter) }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 18) {
            TopBar(section: .clutter) {
                HStack(spacing: 4) {
                    tabButton("Arquivos grandes", 0)
                    tabButton("Duplicados", 1)
                }
                .padding(4)
                .background(Capsule().fill(Color.ink.opacity(0.07)))
            }
            if state.clutterTab == 0 { large } else { dups }
        }
        .confirmationDialog("Mover \(FS.fmt(state.selectedLarge)) para a Lixeira?", isPresented: $confirmLarge) {
            Button("Mover", role: .destructive) { Task { await state.trashLarge() } }
        } message: {
            Text("Confira se não é mídia de um projeto ativo. Dá para recuperar pela Lixeira.")
        }
        .confirmationDialog("Mover duplicados para a Lixeira?", isPresented: $confirmDups) {
            Button("Mover", role: .destructive) { Task { await state.clean(junk: false, dups: true) } }
        } message: {
            Text("Confira antes: um duplicado pode ser mídia usada num projeto do Premiere. Se a pasta sincroniza com Google Drive/iCloud, apagar aqui apaga na nuvem também.")
        }
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { state.clutterTab = i } } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(state.clutterTab == i ? Color.ink : Color.clear))
                .foregroundStyle(state.clutterTab == i ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(state.largeFiles.count) arquivos acima de 200 MB · \(FS.fmt(state.largeTotal))")
                .font(.system(size: 30, weight: .light))
            if state.largeFiles.isEmpty {
                EmptyState(icon: "externaldrive", title: "Nenhum arquivo gigante",
                           text: "Procuro em Downloads, Mesa, Documentos, Filmes e Música.")
            } else {
                GlassCard(padding: 12) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(state.largeFiles) { ItemRow(item: $0); Divider().overlay(Color.ink.opacity(0.08)) }
                        }
                    }
                }
            }
            ActionDock(section: .clutter, label: "Selecionado: \(FS.fmt(state.selectedLarge))", button: "Remover",
                       enabled: state.selectedLarge > 0) { confirmLarge = true }
        }
    }

    private var dups: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(state.dupExtraCount) cópias · \(FS.fmt(state.dupWasted)) repetidos")
                .font(.system(size: 30, weight: .light))
            if state.duplicates.isEmpty {
                EmptyState(icon: "doc.on.doc", title: "Nenhum duplicado",
                           text: "Comparo o conteúdo dos arquivos (não só o nome) em Downloads e na Mesa.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(state.duplicates) { g in
                            GlassCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("\(g.files.count) cópias idênticas").font(.headline)
                                        Spacer()
                                        Text("\(FS.fmt(g.wasted)) repetidos").foregroundStyle(Color.ink.opacity(0.76)).monospacedDigit()
                                    }
                                    .padding(.bottom, 4)
                                    ForEach(Array(g.files.enumerated()), id: \.element.id) { i, f in
                                        ItemRow(item: f, badge: i == 0 ? "ORIGINAL" : nil)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            ActionDock(section: .clutter, label: "Selecionado: \(FS.fmt(state.selectedDups)) · nada vem marcado, escolha você",
                       button: "Remover", enabled: state.selectedDups > 0) { confirmDups = true }
        }
    }
}

// MARK: - Aplicativos

struct AppsView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var current: AppEntry?
    @State private var leftovers: [FileItem] = []
    @State private var loadingLeftovers = false
    @State private var confirm = false

    private var filtered: [AppEntry] {
        query.isEmpty ? state.apps : state.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        if state.scanned.contains(.apps) { results } else { ModuleIntro(section: .apps) }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 18) {
            TopBar(section: .apps) {
                TextField("Buscar app", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Text("\(state.apps.count) apps encontrados no Mac")
                .font(.system(size: 30, weight: .light))
            HStack(spacing: 16) {
                GlassCard(padding: 8) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { app in
                                Button { current = app } label: {
                                    HStack(spacing: 10) {
                                        Image(nsImage: IconCache.icon( app.url.path))
                                            .resizable().frame(width: 30, height: 30)
                                        Text(app.name).lineLimit(1)
                                        Spacer()
                                        Text(FS.fmt(app.size)).foregroundStyle(Color.ink.opacity(0.76)).monospacedDigit()
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(current == app ? Color.ink.opacity(0.18) : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(width: 340)

                GlassCard {
                    if let app = current {
                        detail(app)
                    } else {
                        VStack(spacing: 18) {
                            GlassHero(symbol: "xmark.app.fill", tint: Section.apps.accent, size: 120, animated: false)
                            Text("Escolha um app à esquerda").foregroundStyle(Color.ink.opacity(0.75))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task(id: current) {
            guard let app = current else { return }
            loadingLeftovers = true
            let found = await Task.detached { Scanner.leftovers(for: app) }.value
            leftovers = found
            state.setAll(found, true)
            loadingLeftovers = false
        }
        .confirmationDialog("Desinstalar \(current?.name ?? "")?", isPresented: $confirm) {
            Button("Desinstalar", role: .destructive) {
                guard let app = current else { return }
                let chosen = leftovers.filter { state.selected.contains($0.url) }
                Task {
                    await state.uninstall(app, leftovers: chosen)
                    if !state.apps.contains(app) { current = nil; leftovers = [] }
                }
            }
        } message: {
            Text("O app será fechado e tudo vai para a Lixeira.")
        }
    }

    private func detail(_ app: AppEntry) -> some View {
        let leftSize = state.selectedSize(leftovers)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Image(nsImage: IconCache.icon( app.url.path)).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.title.bold())
                    Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(Color.ink.opacity(0.74))
                }
                Spacer()
            }
            HStack(spacing: 28) {
                stat("App", FS.fmt(app.size))
                stat("Restos", "\(leftovers.count)")
                stat("Total a liberar", FS.fmt(app.size + leftSize))
            }
            Divider().overlay(Color.ink.opacity(0.15))
            Text("Arquivos de suporte, preferências e caches").font(.headline)
            if loadingLeftovers {
                ProgressView().frame(maxWidth: .infinity)
            } else if leftovers.isEmpty {
                Text("Nenhum resto encontrado na sua Biblioteca.").foregroundStyle(Color.ink.opacity(0.76))
            } else {
                ScrollView { VStack(spacing: 0) { ForEach(leftovers) { ItemRow(item: $0) } } }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                RoundAction(title: "Remover", tint: Section.apps.accent, busy: state.isWorking, size: 88) { confirm = true }
                Spacer()
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink.opacity(0.74))
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
        }
    }
}

// MARK: - Desempenho (tela em Perf.swift)

struct TaskCard: View {
    let icon: String
    let title: String
    let text: String
    var button = "Executar"
    let action: () -> Void
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                IconTile(symbol: icon, size: 38)
                Text(title).font(.headline).padding(.top, 4)
                Text(text).font(.caption).foregroundStyle(Color.ink.opacity(0.76)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                HStack { Spacer(); PillButton(title: button, action: action) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Atividades

struct ActivityView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor

    private var health: (String, Color) {
        let free = 1 - monitor.diskUsedFraction
        if free < 0.05 { return ("Crítica", Theme.red) }
        if free < 0.15 { return ("Atenção", Theme.warm) }
        return ("Boa", Theme.teal)
    }

    private var recommendations: [(String, String, String, Section)] {
        var r: [(String, String, String, Section)] = []
        if monitor.diskUsedFraction > 0.9 {
            r.append(("icloud.and.arrow.up.fill", "Mande arquivos pesados para a nuvem",
                      "Vídeos e projetos sem uso vão para o Drive e liberam o disco.", .cloud))
            r.append(("circle.dashed.inset.filled", "Seu disco está quase cheio",
                      "Use a Lupa de espaço para achar as pastas que mais pesam.", .lens))
        }
        if state.junkTotal > 1_000_000_000 {
            r.append(("bubbles.and.sparkles.fill", "\(FS.fmt(state.junkTotal)) de lixo encontrados",
                      "Revise a Limpeza e libere espaço com segurança.", .cleanup))
        }
        if state.dupExtraCount > 0 {
            r.append(("doc.on.doc.fill", "\(state.dupExtraCount) cópias repetidas",
                      "Confira em Acúmulos o que pode sair.", .clutter))
        }
        if !state.hasScanned {
            r.append(("sparkles", "Faça uma análise completa",
                      "O Cuidado inteligente revisa tudo de uma vez.", .home))
        }
        return r
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .lastTextBaseline) {
                    Text("Atividades").font(.system(size: 44, weight: .thin))
                    Spacer()
                    if let d = state.lastClean {
                        Text("Última limpeza: \(d.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76))
                    }
                }
                .padding(.top, 36)

                HStack(alignment: .top, spacing: 18) {
                    GlassCard(padding: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Saúde do Mac:").font(.system(size: 16)).foregroundStyle(Color.ink.opacity(0.8))
                            Text(health.0).font(.system(size: 34, weight: .light)).foregroundStyle(health.1)
                            Text(AppState.machineName).font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76))
                            Spacer(minLength: 40)
                            HStack {
                                Text("Macintosh HD").font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text("\(FS.fmt(monitor.diskUsed)) de \(FS.fmt(monitor.diskTotal)) usados")
                                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.ink.opacity(0.15))
                                    Capsule().fill(LinearGradient(colors: [Theme.teal, health.1], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: g.size.width * monitor.diskUsedFraction)
                                }
                            }
                            .frame(height: 7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 300)
                    .overlay(alignment: .topTrailing) {
                        GlassHero(symbol: "laptopcomputer", tint: health.1, radius: 999, size: 130, animated: false)
                            .padding(22)
                    }

                    GlassCard(padding: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Liberado de verdade (medido)").font(.system(size: 16)).foregroundStyle(Color.ink.opacity(0.8))
                            Text(FS.fmt(state.freedTotal)).font(.system(size: 38, weight: .light)).monospacedDigit()
                            Text("\(state.cleanCount) limpezas feitas").font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76))
                            Spacer(minLength: 20)
                            VStack(spacing: 10) {
                                legend("Lixo encontrado agora", FS.fmt(state.junkTotal), Theme.green)
                                legend("Duplicados", FS.fmt(state.dupWasted), Theme.orange)
                                legend("Arquivos grandes", FS.fmt(state.largeTotal), Theme.purple)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 300)

                    GlassCard(padding: 24) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Agora").font(.system(size: 16)).foregroundStyle(Color.ink.opacity(0.8))
                            Ring(value: monitor.cpu, label: "CPU", detail: "\(Int(monitor.cpu * 100))% em uso", tint: Theme.warm)
                            Ring(value: monitor.memFraction, label: "MEMÓRIA",
                                 detail: "\(FS.fmt(Int64(monitor.memUsed))) de \(FS.fmt(Int64(monitor.memTotal)))", tint: Theme.purple)
                            Ring(value: monitor.diskUsedFraction, label: "DISCO",
                                 detail: "\(FS.fmt(monitor.diskFree)) livres", tint: Theme.blue)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 250, height: 300)
                }

                if !state.receipts.isEmpty {
                    Text("Histórico medido no disco").font(.system(size: 15)).foregroundStyle(Color.ink.opacity(0.75)).padding(.top, 6)
                    GlassCard(padding: 12) {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Ação").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Estimado").frame(width: 90, alignment: .trailing)
                                Text("Real").frame(width: 90, alignment: .trailing)
                                Text("Na Lixeira").frame(width: 90, alignment: .trailing)
                                Text("Quando").frame(width: 140, alignment: .trailing)
                            }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.74))
                            .padding(.bottom, 6)
                            ForEach(state.receipts.prefix(10)) { r in
                                Divider().overlay(Theme.hairline)
                                HStack {
                                    Text(r.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(FS.fmt(r.estimated)).foregroundStyle(Color.ink.opacity(0.76)).frame(width: 90, alignment: .trailing)
                                    Text(FS.fmt(r.real)).foregroundStyle(r.real > 0 ? Theme.green : Color.ink.opacity(0.6)).frame(width: 90, alignment: .trailing)
                                    Text(r.trashed > 0 ? FS.fmt(r.trashed) : "—").foregroundStyle(r.trashed > 0 ? Theme.orange : Color.ink.opacity(0.4)).frame(width: 90, alignment: .trailing)
                                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Color.ink.opacity(0.74)).frame(width: 140, alignment: .trailing)
                                }
                                .font(.system(size: 12)).monospacedDigit()
                                .padding(.vertical, 7)
                            }
                        }
                    }
                }
                Text("\(recommendations.count) recomendações").font(.system(size: 15)).foregroundStyle(Color.ink.opacity(0.75))
                    .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                    ForEach(recommendations, id: \.1) { rec in
                        Button { state.section = rec.3 } label: {
                            GlassCard {
                                HStack(spacing: 16) {
                                    IconTile(symbol: rec.0, size: 44)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(rec.1).font(.system(size: 15, weight: .semibold))
                                        Text(rec.2).font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.76))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Color.ink.opacity(0.74))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 40)
        }
    }

    private func legend(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
    }
}
