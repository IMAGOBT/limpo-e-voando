# Limpo e Voando

App para macOS 13 Ventura ou mais novo que libera espaço e deixa o Mac rápido: limpeza, desempenho, rotinas automáticas, organizador de pastas, lupa de espaço, duplicados, desinstalador, nuvem (Google Drive), backup e compressor.
O módulo Celular → Drive é **bônus, em teste**.

## Instalar
1. Baixe o `.dmg` em **Releases**:
   - **Mac novo (chip Apple, M1 em diante):** `Limpo-e-Voando-…-Mac-novo-chip-Apple.dmg`
   - **Mac antigo (Intel):** `Limpo-e-Voando-…-Mac-antigo-Intel.dmg`
   - Não sabe qual? Menu  → Sobre Este Mac: se aparecer "Chip Apple", é o novo; "Intel", é o antigo.
2. Arraste **Limpo e Voando** para **Aplicativos**.
3. Na primeira vez: clique com o botão direito no app → **Abrir** → **Abrir** (o app não é assinado por desenvolvedor Apple pago).

## Compilar
Requer as Command Line Tools do Xcode.
```bash
./build.sh          # Mac novo (chip Apple)
./build.sh intel    # Mac antigo (Intel)
```

Nada sai do seu Mac: o app não envia dados para servidor nenhum.
