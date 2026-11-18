# Limpo e Voando para Windows

Versão Windows do Limpo e Voando (Electron). Libera espaço e deixa o PC leve: cuidado inteligente, limpeza, acúmulos (grandes e duplicados), desempenho, lupa de espaço, aplicativos, organizar, compressor e baixar vídeo.

Nada sai do seu PC. As únicas conexões são o download do yt-dlp (GitHub) e do ffmpeg (gyan.dev) no primeiro uso, e os próprios sites dos vídeos que você baixar.

## Instalar
Baixe nos artefatos do GitHub Actions (workflow **Windows (Limpo e Voando)**):
- `Limpo-e-Voando-<versão>-Instalador.exe`: instalador, deixa escolher a pasta e cria atalho na Área de Trabalho.
- `Limpo-e-Voando-<versão>-Portatil.exe`: roda sem instalar.

O app não é assinado. Na primeira vez o Windows SmartScreen pode avisar: clique em **Mais informações → Executar assim mesmo**.

## Compilar
Requer Node 22 ou mais novo.
```bash
cd windows
npm ci                # ou npm install
npm run check         # node --check em todos os .js
npm test              # testes da lógica pura
npm start             # abre o app
npm run build:win     # gera dist/*-Instalador.exe e dist/*-Portatil.exe (rodar no Windows ou no CI)
```

Teste de fumaça (só leitura, não apaga nada):
```bash
npx electron . --smoke --smoke-out=smoke.json
"dist\win-unpacked\Limpo e Voando.exe" --smoke     # app empacotado
```
Ele roda todos os scanners, abre a janela escondida, passa por todas as seções e sai com código 0 se nada deu erro.

Capturas de tela de todas as seções (claro e escuro): `npm run screenshot` (pasta em `LV_SHOTS`).

Ícone: `npm run icon` regenera `build/icon.ico` a partir do `../AppIcon.icns` (precisa do macOS por causa do `sips`).

## Segurança
- Tudo que é do usuário vai para a **Lixeira** (`shell.trashItem`). Só temporários e caches são apagados direto (os apps recriam).
- Nunca mexe em `C:\Windows`, `Program Files`, `ProgramData`, na raiz do perfil nem nas raízes do `AppData`.
- Não segue links simbólicos nem junções; arquivos em uso são pulados e contados.
- Nada que possa ser mídia do usuário vem marcado. Duplicados sempre mantêm uma cópia.
- Exclusões em massa pedem confirmação dupla. "Liberado de verdade" mede o espaço livre do disco antes e depois.
- Desativar item de inicialização é reversível: o valor do registro vai para `HKCU\Software\LimpoEVoando\DisabledRun` e os atalhos para `%LOCALAPPDATA%\LimpoEVoando\DisabledStartup`.

## Estrutura
```
main.js            janela, IPC e modo --smoke
preload.js         ponte mínima (lista fechada de métodos)
src/main/          scanners: cleanup, clutter, perf, apps, lens, organize, media (ffmpeg/yt-dlp), smoke
src/renderer/      HTML/CSS/JS puro (sem framework)
test/              testes de node:test da lógica pura
```
