#!/bin/bash
# Compila e empacota o Limpo e Voando.app (não precisa do Xcode, só das Command Line Tools)
set -euo pipefail
cd "$(dirname "$0")"

# Uso: ./build.sh            → Mac novo (chip Apple)
#      ./build.sh intel      → Mac antigo (Intel)
ARCH="${1:-apple}"
if [ "$ARCH" = "intel" ]; then
  swift build -c release --triple x86_64-apple-macosx13.0
  BIN=".build/x86_64-apple-macosx/release/ImagoCare"
  OUT="build/intel"
else
  swift build -c release --triple arm64-apple-macosx13.0
  BIN=".build/arm64-apple-macosx/release/ImagoCare"
  OUT="build"
fi

# Monta e assina numa pasta temporária (pastas sincronizadas adicionam atributos que quebram o codesign)
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Limpo e Voando.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ImagoCare"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# idioma: português do Brasil (botões do sistema como "Cancelar" em PT-BR)
mkdir -p "$APP/Contents/Resources/pt-BR.lproj"
printf '"CFBundleDisplayName" = "Limpo e Voando";\n' > "$APP/Contents/Resources/pt-BR.lproj/InfoPlist.strings"
xattr -cr "$APP"
# hardened runtime: impede injeção de bibliotecas no app (que tem acesso às suas pastas)
codesign --force --options runtime --entitlements app.entitlements -s - "$APP/Contents/MacOS/ImagoCare"
codesign --force --options runtime --entitlements app.entitlements -s - "$APP"
mkdir -p "$OUT" && rm -rf "$OUT/Limpo e Voando.app"
ditto "$APP" "$OUT/Limpo e Voando.app"
APP="$OUT/Limpo e Voando.app"

echo "✅ Pronto: $(pwd)/$APP"
echo "   Para instalar: arraste para /Applications"
