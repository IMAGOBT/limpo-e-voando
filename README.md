# Limpo e Voando

**Seu computador limpo, leve e rápido.** O Limpo e Voando encontra o que só ocupa espaço, mostra o que está pesando no disco e deixa você decidir o que sai. Tudo com segurança: quase tudo vai para a Lixeira, nada sensível vem marcado e nenhum dado seu sai do computador.

Feito pela [Imago Studio](https://imagostudio.art). Gratuito, em português.

| | Versão | Requisito |
|---|---|---|
| 🍏 **Mac novo** (chip Apple, M1 em diante) | `Limpo-e-Voando-…-Mac-novo-chip-Apple.dmg` | macOS 13 Ventura ou mais novo |
| 🍎 **Mac antigo** (Intel) | `Limpo-e-Voando-…-Mac-antigo-Intel.dmg` | macOS 13 Ventura ou mais novo |
| 🪟 **Windows** | `Limpo-e-Voando-…-Windows-Setup.exe` (ou a versão portátil) | Windows 10 ou 11, 64 bits |

👉 **[Baixar a versão mais nova](../../releases/latest)**

> **No Windows** o app tem Cuidado inteligente, Limpeza, Acúmulos, Desempenho, Lupa de espaço, Aplicativos, Organizar, Compressor e Baixar vídeo. Rotinas, Nuvem, Backup e Celular existem só no Mac, por enquanto.

---

## O que o app faz

### Espaço
- **Cuidado inteligente**: uma análise só, com quatro buscas em paralelo (lixo, duplicados, arquivos grandes e o que abre com o computador). Mostra tudo num painel de cartões.
- **Limpeza**: caches de apps, logs, restos de instaladores, cache de mídia do Premiere/After Effects, caches de IA e de programação (`node_modules`, DerivedData…). Mostra o tamanho de cada categoria, e você escolhe item por item.
- **Acúmulos**: arquivos acima de 200 MB e **duplicados de verdade** (compara o conteúdo, não só o nome). Sempre sobra pelo menos uma cópia.
- **Lupa de espaço**: um mapa em rosca colorido mostra o que ocupa cada pasta. Dá para entrar nas pastas, abrir no Finder e mandar para a Lixeira. Também existe a **Lupa do Google Drive**.
- **Aplicativos**: desinstala por completo, junto com os restos espalhados pela Biblioteca.
- **Espaço real medido**: depois de cada limpeza, o app mede o disco antes e depois e mostra quanto foi **liberado de verdade**, não uma estimativa.

### Desempenho
- Medidores de CPU, memória e disco ao vivo.
- Mostra os apps pesados agora e encerra com um clique.
- Mostra os agentes que rodam em segundo plano e os itens de inicialização.
- **Preparar para exportar**: antes de renderizar um vídeo, confere o espaço, fecha os apps pesados e libera memória.

### Processos rápidos
- **Rotinas automáticas**: instaladores, capturas de tela, gerações de IA e Downloads antigos saem sozinhos, no dia e na regra que você configurar.
- **Organizar pastas**: arruma o Downloads (ou outra pasta) por tipo, por data, por extensão ou por site de origem. Mostra uma prévia antes, nunca sobrescreve e dá para desfazer.
- **Nuvem**: manda os arquivos pesados para o Google Drive e só libera o espaço no Mac **depois** que o upload termina.
- **Backup para o Drive**: você escolhe as pastas, o dia e o horário. Pode manter nos dois lugares ou mover e liberar o Mac.
- **Compressor**: vídeos em HEVC (H.265), PDFs mais leves e áudio para MP3. O original só sai quando a conversão deu certo.
- **Baixar vídeo**: cole o link do **Instagram, Pinterest, YouTube ou TikTok** e o vídeo chega na maior qualidade, **até 4K**. A fila baixa um vídeo por vez e converte para um formato que abre no QuickTime e no Premiere. Quando o Instagram pede login, o app usa o login do seu navegador.
- **Celular → Drive** *(bônus, em teste, só no Mac)*: conecte o iPhone (ou Android) no cabo. As fotos e vídeos vão para o Drive organizados por data e por assunto, e dá para apagar do celular o que já está salvo.

### Visual
- Modo claro, escuro ou seguindo o sistema (seletor no rodapé da barra lateral).
- Cores com significado: azul = destaque, verde = positivo, vermelho = negativo, laranja = atenção.
- Gráficos coloridos e barra de % em cada análise.
- Atalhos ⌘1–⌘9 para as seções.

---

## Segurança e privacidade
- **Tudo vai para a Lixeira.** A exceção são caches e arquivos temporários, que os próprios apps recriam.
- **Nada vem marcado** quando pode ser um arquivo de projeto, da nuvem ou um modelo de IA. Você decide.
- **Pastas do sistema nunca são tocadas** (nem a Biblioteca inteira, nem a pasta pessoal inteira).
- **Nenhum dado seu sai do computador.** O app só se conecta aos sites dos vídeos que você pede para baixar e para atualizar o motor de download (o [yt-dlp](https://github.com/yt-dlp/yt-dlp) oficial).
- O que está na nuvem só é liberado do disco depois que o upload é confirmado.

---

## Instalar

### Mac
1. Baixe o `.dmg` certo em **[Releases](../../releases/latest)**. Para saber qual é o seu Mac: menu  → **Sobre Este Mac**. Se aparecer "Chip Apple", baixe a versão do Mac novo; se aparecer "Intel", a do Mac antigo.
2. Abra o `.dmg` e arraste **Limpo e Voando** para **Aplicativos**.
3. Na primeira vez, clique com o botão direito no app → **Abrir** → **Abrir**. O app não tem a assinatura paga da Apple.
4. Para o 4K e a conversão de vídeo, o app usa o [ffmpeg](https://ffmpeg.org). Se ele faltar, o próprio app mostra como instalar (pelo [Homebrew](https://brew.sh)).

### Windows
1. Baixe `Limpo-e-Voando-…-Windows-Setup.exe` em **[Releases](../../releases/latest)** e instale. A versão portátil roda sem instalar.
2. Se o Windows mostrar "O Windows protegeu o computador", clique em **Mais informações → Executar assim mesmo**. O app não tem certificado pago.

---

## Para desenvolvedores

**Mac** (SwiftUI, sem Xcode, só as Command Line Tools):
```bash
./build.sh          # Mac novo (chip Apple)
./build.sh intel    # Mac antigo (Intel)
```

**Windows** (Electron): veja [`windows/README.md`](windows/README.md). O instalador é gerado e testado automaticamente no GitHub Actions (`.github/workflows/windows.yml`).

---

Feito com cuidado no Brasil 🇧🇷 · [Imago Studio](https://imagostudio.art)
