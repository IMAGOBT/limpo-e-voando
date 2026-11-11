import SwiftUI
import AppKit

// MARK: - Cores e aparência

extension Color {
    /// Tinta: branco no modo escuro, quase preto no claro. Use com opacidade para hierarquia.
    static let ink = Color(nsColor: NSColor(name: "ink") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.98, alpha: 1) : NSColor(white: 0.07, alpha: 1)
    })
    /// Papel: o oposto da tinta (fundo de botões invertidos).
    static let paper = Color(nsColor: NSColor(name: "paper") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.05, alpha: 1) : NSColor(white: 0.99, alpha: 1)
    })
}

enum Theme {
    /// Paleta dos gráficos: cores do sistema Apple, vivas e ajustadas para claro/escuro.
    static let chart: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemPurple), Color(nsColor: .systemPink),
        Color(nsColor: .systemOrange), Color(nsColor: .systemYellow), Color(nsColor: .systemGreen),
        Color(nsColor: .systemTeal),
    ]
    static let indigo = Color(nsColor: .systemIndigo)
    static let teal2 = Color(nsColor: .systemTeal)
    static let purple = Color(nsColor: .systemPurple)
    // Cores com significado: vivas no escuro, mais escuras no claro (texto legível sobre branco)
    static let blue = adaptive(light: (0.00, 0.40, 0.85), dark: (0.25, 0.62, 1.00))     // destaque, seleção, progresso
    static let green = adaptive(light: (0.10, 0.52, 0.22), dark: (0.25, 0.85, 0.42))    // positivo: liberado, ok
    static let red = adaptive(light: (0.80, 0.16, 0.12), dark: (1.00, 0.42, 0.38))      // negativo: erro, crítico
    static let orange = adaptive(light: (0.70, 0.36, 0.00), dark: (1.00, 0.66, 0.25))   // atenção
    static let yellow = adaptive(light: (0.60, 0.46, 0.00), dark: (1.00, 0.84, 0.30))   // aviso leve

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    // nomes antigos usados pelo app
    static let teal = green
    static let warm = orange
    static let violet = blue
    static var hairline: Color { Color.ink.opacity(0.10) }
}

/// As três cores de fundo do app.
enum Palette {
    static let navyTop = Color(red: 0.055, green: 0.105, blue: 0.215)
    static let navyBottom = Color(red: 0.025, green: 0.055, blue: 0.130)
    static let navyCard = Color(red: 0.085, green: 0.150, blue: 0.290)
}

/// Aparência como nos Ajustes do Mac: Sistema, Claro ou Escuro.
enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system, light, dark
    var id: Int { rawValue }
    static let key = "appearance.v2"
    static var current: AppearanceMode { AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .system }
    var icon: String { self == .light ? "sun.max" : self == .dark ? "moon" : "circle.lefthalf.filled" }
    var label: String { self == .light ? "Claro" : self == .dark ? "Escuro" : "Sistema" }

    /// Aplica no app inteiro (janela, menus, barra de menus e folhas).
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Fundo: papel ou grafite, luz suave e linha de horizonte

struct Backdrop: View {
    let section: Section
    var navy = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        // fundo sólido, sem degradê
        let base: Color = navy ? Palette.navyBottom : (dark ? Color(white: 0.06) : Color(white: 0.975))
        ZStack {
            base
            // horizonte: linha de luz finíssima
            VStack {
                Spacer()
                LinearGradient(colors: [.clear, Color.ink.opacity(dark ? 0.16 : 0.10), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                    .padding(.bottom, 120)
            }
            Grain().opacity(dark ? 0.03 : 0.018).blendMode(dark ? .overlay : .multiply)
        }
        .ignoresSafeArea()
    }
}

/// Textura de grão sutil.
struct Grain: View {
    var body: some View {
        Image(nsImage: GrainTile.image)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}

// MARK: - Objeto 3D de vidro (fumê no escuro, fosco no claro)

struct GlassHero: View {
    let symbol: String
    let tint: Color
    var radius: CGFloat = 80
    var size: CGFloat = 300
    var animated = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var float = false

    var body: some View {
        let dark = scheme == .dark
        let r = min(radius * size / 300, size / 2)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        let line = max(0.8, size * 0.0045)
        let body: [Color] = dark ? [Color(white: 0.26), Color(white: 0.07), Color(white: 0.15)]
                                 : [Color(white: 1.0), Color(white: 0.86), Color(white: 0.94)]
        ZStack {
            Ellipse()
                .fill(.black.opacity(dark ? 0.55 : 0.18))
                .frame(width: size * 0.78, height: size * 0.10)
                .blur(radius: size * 0.05)
                .offset(y: size * 0.56)
                .scaleEffect(animated && float ? 0.92 : 1)
            shape
                .fill(LinearGradient(colors: body, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(RadialGradient(colors: [Theme.blue.opacity(dark ? 0.16 : 0.10), .clear],
                                                   center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: size * 0.8)))
                .shadow(color: .black.opacity(dark ? 0.6 : 0.16), radius: size * 0.08, y: size * 0.08)
            shape
                .fill(LinearGradient(colors: [Color.white.opacity(dark ? 0.28 : 0.85), Color.white.opacity(0)],
                                     startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.42)))
                .blendMode(dark ? .screen : .normal)
            shape
                .strokeBorder(LinearGradient(colors: dark ? [Color.white.opacity(0.85), Color.white.opacity(0.05), Color.white.opacity(0.30)]
                                                           : [Color.white, Color.black.opacity(0.10), Color.black.opacity(0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: line)
            RoundedRectangle(cornerRadius: r * 0.72, style: .continuous)
                .strokeBorder(Color.ink.opacity(dark ? 0.12 : 0.08), lineWidth: line)
                .padding(size * 0.14)
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .light))
                .foregroundStyle(dark ? Color.white : Color(white: 0.16))
                .shadow(color: dark ? Color.white.opacity(0.35) : Color.black.opacity(0.10), radius: size * 0.04)
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(animated && float ? 11 : 8), axis: (x: 1, y: -0.8, z: 0), perspective: 0.55)
        .offset(y: animated && float ? -5 : 4)
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { float = true }
        }
    }
}

// MARK: - Botão principal (Analisar / Limpar / Executar)

struct RoundAction: View {
    let title: String
    var subtitle: String? = nil
    let tint: Color
    var busy = false
    var enabled = true
    var size: CGFloat = 112
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var hover = false

    var body: some View {
        let dark = scheme == .dark
        // escuro: disco perolado com texto preto · claro: disco grafite com texto branco
        let disc: [Color] = dark ? [.white, Color(white: 0.86), Color(white: 0.70)]
                                 : [Color(white: 0.28), Color(white: 0.12), Color(white: 0.05)]
        let label = dark ? Color(white: 0.08) : Color.white
        Button(action: action) {
            ZStack {
                if !busy {   // durante a análise, nada pulsando: só a barra de %
                    Circle()
                        .stroke(Theme.blue.opacity(0.55), lineWidth: 0.9)
                        .scaleEffect(pulse ? 1.45 : 1)
                        .opacity(pulse ? 0 : 0.9)
                }
                Circle()
                    .fill(RadialGradient(colors: disc, center: UnitPoint(x: 0.4, y: 0.25), startRadius: 0, endRadius: size * 0.75))
                    .overlay(Circle().strokeBorder(Color.white.opacity(dark ? 0.9 : 0.25), lineWidth: 0.8))
                    .shadow(color: Theme.blue.opacity(hover ? 0.45 : 0.22), radius: hover ? 30 : 22)
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 10, y: 8)
                if busy {
                    ProgressView().controlSize(.large).tint(label)
                } else {
                    VStack(spacing: 2) {
                        Text(title).font(.system(size: size * 0.16, weight: .medium)).tracking(0.3)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 10.5, weight: .medium)).monospacedDigit().opacity(0.7)
                        }
                    }
                    .foregroundStyle(label)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(hover && enabled ? 1.03 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hover)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: - Barra lateral (só ícones + etiqueta ao passar o mouse)

struct Sidebar: View {
    @EnvironmentObject var state: AppState
    @State private var hovered: Section?

    var body: some View {
        VStack(spacing: 3) {
            Spacer().frame(height: 46)
            ForEach(Section.main) { button($0) }
            Rectangle().fill(Theme.hairline).frame(width: 26, height: 1).padding(.vertical, 7)
            ForEach(Section.quick) { button($0) }
            Spacer()
            button(.tools)
            button(.activity)
            AppearanceButton()
                .padding(.bottom, 16)
        }
        .frame(width: 76)
        .background(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        .zIndex(2)
    }

    private func button(_ s: Section) -> some View {
        let on = state.section == s
        return Button { withAnimation(.easeInOut(duration: 0.35)) { state.section = s } } label: {
            Image(systemName: s.icon)
                .font(.system(size: 16, weight: on ? .medium : .regular))
                .foregroundStyle(Color.ink.opacity(on ? 1 : (hovered == s ? 0.95 : 0.74)))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.ink.opacity(on ? 0.09 : (hovered == s ? 0.05 : 0)))
                )
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.ink.opacity(on ? 0.16 : 0), lineWidth: 0.6))
                .overlay(alignment: .topTrailing) {
                    if state.busy == s {
                        Circle().fill(Theme.blue).frame(width: 6, height: 6).shadow(color: Theme.blue, radius: 4).offset(x: -4, y: 4)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.title)
        .modifier(SectionShortcut(section: s))
        // indicador de luz à esquerda do item ativo
        .overlay(alignment: .leading) {
            Capsule().fill(Theme.blue)
                .frame(width: 2.5, height: on ? 18 : 0)
                .shadow(color: Theme.blue.opacity(0.7), radius: 4)
                .offset(x: -16)
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: on)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovered = h ? s : (hovered == s ? nil : hovered) } }
        .overlay(alignment: .leading) {
            if hovered == s {
                // etiqueta invertida: sempre contraste máximo (escura no claro, clara no escuro)
                HStack(spacing: 8) {
                    Text(s.title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.paper)
                    if let i = (Section.main + Section.quick).firstIndex(of: s), i < 9 {
                        Text("⌘\(i + 1)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.paper.opacity(0.75))
                    }
                }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.ink))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .fixedSize()
                    .offset(x: 56)
                    .transition(.opacity.combined(with: .offset(x: -4)))
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Peças comuns

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.ink.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.ink.opacity(0.11), lineWidth: 0.7))
    }
}

/// Barra do topo das telas de resultado: "Recomeçar" à esquerda, título ao centro.
struct TopBar<Trailing: View>: View {
    let section: Section
    @ViewBuilder var trailing: Trailing
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            Text(section.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.9))
            HStack {
                Button { state.reset(section) } label: {
                    Label("Recomeçar", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.85))
                Spacer()
                trailing
            }
        }
        .frame(height: 30)
    }
}

extension TopBar where Trailing == EmptyView {
    init(section: Section) { self.init(section: section) { EmptyView() } }
}

struct CheckBox: View {
    let state: Int // 0 off, 1 on, 2 parcial
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(state == 0 ? Color.clear : Color.ink)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.ink.opacity(state == 0 ? 0.62 : 1), lineWidth: 1.5)
                if state != 0 {
                    Image(systemName: state == 1 ? "checkmark" : "minus")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.paper)
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

struct PillButton: View {
    let title: String
    var icon: String? = nil
    var prominent = true
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.ink) : AnyShapeStyle(Color.ink.opacity(0.09))))
            .overlay(Capsule().strokeBorder(Color.ink.opacity(prominent ? 0 : 0.26), lineWidth: 0.8))
            .foregroundStyle(prominent ? Color.paper : Color.ink)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Rodapé das telas de resultado: resumo à esquerda, botão redondo no centro.
struct ActionDock: View {
    let section: Section
    let label: String
    let button: String
    let enabled: Bool
    let action: () -> Void
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            HStack {
                Text(label).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(Color.ink.opacity(0.85))
                Spacer()
            }
            RoundAction(title: button, tint: section.accent, busy: state.isWorking,
                        enabled: enabled, size: 96, action: action)
        }
        .frame(height: 100)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    var tint: Color = Color.ink
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(tint)
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(Color.ink.opacity(0.76)).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ItemRow: View {
    let item: FileItem
    var badge: String? = nil
    var selectable = true
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            if selectable {
                CheckBox(state: state.selected.contains(item.url) ? 1 : 0) { state.toggle(item.url) }
            }
            Image(nsImage: IconCache.icon( item.url.path))
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).lineLimit(1)
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.ink.opacity(0.22)))
                    }
                }
                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~"))
                    .font(.caption).foregroundStyle(Color.ink.opacity(0.74))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let d = item.modified {
                Text(d, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption).foregroundStyle(Color.ink.opacity(0.74))
            }
            Text(FS.fmt(item.size)).monospacedDigit().foregroundStyle(Color.ink.opacity(0.85)).frame(minWidth: 70, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain).foregroundStyle(Color.ink.opacity(0.74)).help("Mostrar no Finder")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

struct Ring: View {
    let value: Double
    let label: String
    let detail: String
    var tint: Color = Color.ink
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.ink.opacity(0.15), lineWidth: 5)
                Circle().trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: value)
                Text("\(Int(value * 100))").font(.system(size: 11, weight: .bold)).monospacedDigit()
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink.opacity(0.74))
                Text(detail).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
        }
    }
}

extension Color {
    /// Mistura duas cores (compatível com macOS 14).
    func blend(_ other: Color, _ fraction: CGFloat) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        return Color(nsColor: a.blended(withFraction: fraction, of: b) ?? a)
    }
}

/// Seletor de aparência sempre visível: Sistema · Claro · Escuro.
struct AppearanceButton: View {
    @AppStorage(AppearanceMode.key) private var mode = 0
    var body: some View {
        HStack(spacing: 1) {
            ForEach(AppearanceMode.allCases) { a in
                let on = mode == a.rawValue
                Button {
                    mode = a.rawValue
                    a.apply()
                } label: {
                    Image(systemName: a.icon)
                        .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.paper : Color.ink.opacity(0.74))
                        .frame(width: 20, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.ink : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(a.label)
                .accessibilityLabel("Aparência: \(a.label)")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ink.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ink.opacity(0.12), lineWidth: 0.7))
        .animation(.easeOut(duration: 0.15), value: mode)
    }
}

/// Ícone padrão do app: ladrilho 32×32, canto 9, traço fino. Use em listas, cards e recursos.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 32
    var tint: Color? = nil          // cor de estado (verde/laranja/vermelho) quando fizer sentido
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint ?? Color.ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.ink.opacity(0.18), lineWidth: 0.8))
    }
}

/// ⌘1…⌘9 para as primeiras seções da barra lateral.
struct SectionShortcut: ViewModifier {
    let section: Section
    func body(content: Content) -> some View {
        let order = Section.main + Section.quick
        if let i = order.firstIndex(of: section), i < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

/// Ícones do Finder em cache (evita pedir ao sistema a cada redesenho de lista).
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 800; return c }()
    static func icon(_ path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}

/// Grão gerado uma única vez como textura, repetida em mosaico (barato de desenhar).
enum GrainTile {
    static let image: NSImage = {
        let side = 160
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var rng = SystemRandomNumberGenerator()
        for y in 0..<side { for x in 0..<side {
            let on = Int.random(in: 0..<90, using: &rng) == 0
            rep.setColor(on ? NSColor(white: 0.5, alpha: 1) : .clear, atX: x, y: y)
        } }
        let img = NSImage(size: NSSize(width: side, height: side))
        img.addRepresentation(rep)
        return img
    }()
}

// MARK: - Liquid Glass (macOS 26) com volta automática para versões antigas

extension View {
    /// Vidro líquido da Apple no macOS 26+; material translúcido nas versões anteriores.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(Color.ink.opacity(0.10), lineWidth: 0.7))
        }
    }

    @available(macOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}


// MARK: - Rosca (gráfico de fatias) que roda do macOS 13 em diante

struct Donut: View {
    let slices: [(Double, Color)]
    var inner: CGFloat = 0.62
    var gapDegrees: Double = 1.2

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let total = slices.reduce(0) { $0 + max($1.0, 0) }
            let center = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let outerR = side / 2, innerR = side / 2 * inner
            ZStack {
                if total <= 0 {
                    Circle().stroke(Color.ink.opacity(0.08), lineWidth: outerR - innerR)
                        .frame(width: (outerR + innerR), height: (outerR + innerR))
                        .position(center)
                } else {
                    ForEach(Array(arcs(total).enumerated()), id: \.offset) { _, a in
                        Path { p in
                            p.addArc(center: center, radius: outerR, startAngle: .degrees(a.0), endAngle: .degrees(a.1), clockwise: false)
                            p.addArc(center: center, radius: innerR, startAngle: .degrees(a.1), endAngle: .degrees(a.0), clockwise: true)
                            p.closeSubpath()
                        }
                        .fill(a.2)
                    }
                }
            }
        }
    }

    private func arcs(_ total: Double) -> [(Double, Double, Color)] {
        var start = -90.0
        let gap = slices.count > 1 ? gapDegrees : 0
        return slices.map { v, c in
            let sweep = max(v, 0) / total * 360
            defer { start += sweep }
            let a = start + gap / 2, b = max(a + 0.4, start + sweep - gap / 2)
            return (a, b, c)
        }
    }
}
