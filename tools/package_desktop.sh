#!/bin/sh
# Build the desktop viewer packages with the auto-rig and its weights.
#
#   tools/package_desktop.sh pck <out dir>            export skintokens-viewer.pck from HEAD
#   tools/package_desktop.sh package <out dir> <w>    lay out and archive the three packages
#
# Inputs (environment):
#   ENGINE   dir with godot.macos.editor.double.arm64 and the three template_release runtimes
#            from V-Sekai-fire/service-godot-build v20260930-double.1, plus LICENSE-model-explorer.txt
#   SANDBOX  dir with the godot-sandbox native libraries (CI artifacts of the add-on's main),
#            named libgodot_riscv.<os>.template_release.double.<arch>[.so|.dll|.framework]
#   ELF      skintokens.elf
# <w> holds mesh-encoder.gguf, skin-vae.gguf and tokenrig.gguf.
# The pck is OS-independent; `package` runs anywhere with zip and tar (the Windows desk's WSL is
# fastest for the 1.3 GB archives). Archives store the weights uncompressed (zip -0 for .gguf).
set -eu
cmd=$1 out=$(cd "$2" 2>/dev/null && pwd || (mkdir -p "$2" && cd "$2" && pwd))
here=$(cd "$(dirname "$0")/.." && pwd)

if [ "$cmd" = pck ]; then
  src="$out/src"
  rm -rf "$src" && mkdir -p "$src"
  git -C "$here" archive HEAD | tar -x -C "$src"
  rm -rf "$src/guest"
  mkdir -p "$src/addons/godot_sandbox/bin"
  cp -R "$SANDBOX"/libgodot_riscv.* "$src/addons/godot_sandbox/bin/"
  cat > "$src/addons/godot_sandbox/bin/godot-riscv.gdextension" <<'E'
[configuration]

entry_symbol = "riscv_library_init"
compatibility_minimum = "4.4"

[libraries]
macos.double = "./libgodot_riscv.macos.template_release.double.universal.framework"
windows.double.x86_64 = "./libgodot_riscv.windows.template_release.double.x86_64.dll"
linux.double.x86_64 = "./libgodot_riscv.linux.template_release.double.x86_64.so"
E
  cp "$ELF" "$src/skintokens.elf"
  G="$ENGINE/godot.macos.editor.double.arm64"
  "$G" --headless --path "$src" --import > "$out/import.log" 2>&1 || true
  "$G" --headless --path "$src" --export-pack Linux "$out/skintokens-viewer.pck" > "$out/export.log" 2>&1
  if grep -q "SCRIPT ERROR" "$out/export.log"; then echo "SCRIPT ERROR in export.log"; exit 1; fi
  for f in skintokens.elf godot-riscv.gdextension AutoRig.gd; do
    grep -aq "$f" "$out/skintokens-viewer.pck" || { echo "pck lacks $f"; exit 1; }
  done
  echo "PCK-OK $(wc -c < "$out/skintokens-viewer.pck") bytes"
  exit 0
fi

[ "$cmd" = package ] || { sed -n 2,16p "$0"; exit 2; }
w=$3
for f in mesh-encoder.gguf skin-vae.gguf tokenrig.gguf; do [ -f "$w/$f" ] || { echo "missing $w/$f"; exit 1; }; done
lay() { # <os> <runtime> <exe name> <library>
  d="$out/$1/skintokens-viewer"
  rm -rf "$out/$1" && mkdir -p "$d/w"
  cp "$ENGINE/$2" "$d/$3" && chmod +x "$d/$3"
  cp "$out/skintokens-viewer.pck" "$d/"
  cp -R "$SANDBOX/$4" "$d/"
  cp "$ENGINE/LICENSE-model-explorer.txt" "$d/"
  cp "$w"/mesh-encoder.gguf "$w"/skin-vae.gguf "$w"/tokenrig.gguf "$d/w/"
}
lay macos godot.macos.template_release.double.arm64 skintokens-viewer \
  libgodot_riscv.macos.template_release.double.universal.framework
lay windows godot.windows.template_release.double.x86_64.llvm.exe skintokens-viewer.exe \
  libgodot_riscv.windows.template_release.double.x86_64.dll
lay linux godot.linuxbsd.template_release.double.x86_64 skintokens-viewer \
  libgodot_riscv.linux.template_release.double.x86_64.so
(cd "$out/macos" && rm -f ../skintokens-viewer-macos-arm64.zip && zip -qry -n .gguf ../skintokens-viewer-macos-arm64.zip skintokens-viewer)
(cd "$out/windows" && rm -f ../skintokens-viewer-windows-x86_64.zip && zip -qr -n .gguf ../skintokens-viewer-windows-x86_64.zip skintokens-viewer)
(cd "$out/linux" && tar -cf ../skintokens-viewer-linux-x86_64.tar skintokens-viewer)
(cd "$out" && sha256sum skintokens-viewer-*.zip skintokens-viewer-*.tar > SHA256SUMS 2>/dev/null \
  || shasum -a 256 skintokens-viewer-*.zip skintokens-viewer-*.tar > SHA256SUMS)
cat "$out/SHA256SUMS"
echo PACKAGE-OK
