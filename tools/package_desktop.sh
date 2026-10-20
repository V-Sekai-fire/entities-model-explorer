#!/bin/sh
# Build the desktop viewer packages with the auto-rig and its weights.
#
#   tools/package_desktop.sh pck <out dir>            export skintokens-viewer.pck from HEAD
#   tools/package_desktop.sh package <out dir> <w> [skintokens|kimodo-motion]
#                                                     lay out and archive the three packages
#                                                     in <out dir>/<viewer>/ with SHA256SUMS
#
# One pck, two viewers. Each feature is on when its weights are in the package's w folder:
#   skintokens     skintokens-viewer, the rig weights (R auto-rigs), no Kimodo (the default)
#   kimodo-motion  kimodo-motion-viewer, the Kimodo weights (the Motion list), no rig weights
#
# Inputs (environment):
#   ENGINE   dir with godot.macos.editor.double.arm64 and the three template_release runtimes
#            from V-Sekai-fire/service-godot-build v20260930-double.1, plus LICENSE-model-explorer.txt
#   SANDBOX  dir with the godot-sandbox native libraries (CI artifacts of the add-on's main),
#            named libgodot_riscv.<os>.template_release.double.<arch>[.so|.dll|.framework]
#   ELF      skintokens.elf
#   USD_ELF  usd.elf (interactor-usd-guest), the OpenUSD reader for .usd, .usda, .usdc and .usdz
#   MOTION_ELF  motion.elf (interactor-motion-guest)
#   HEADFIT_ELF optional: headfit.elf (interactor-headfit), the anime eye closes of a rigged VRM.
#            Unset, `pck` downloads it with gh from the newest green `guest` run of
#            interactor-headfit's ${HEADFIT_BRANCH:-main}, and writes where it came from to
#            <out dir>/headfit.elf.source.txt
#   MM_ELF   mm.elf (interactor-motion-matching-guest), the motion-matching controller (M)
#   MUJOCO_ELF  mujoco.elf, double-precision build (mujoco-sandbox-demo project/plans/
#            mujoco.double.elf), the obstacle course's colliders
#   MM_DATA  that repo's clip dirs, ':'-separated (data/kimodo-locomotion:data/o3de-motionmatching):
#            one dir per clip (transforms.f32, skeleton.txt, parents.txt, and loop.txt for a
#            steady gait cut as a loop), the controller's pose
#            database; written into res://motion/mm/
#   NOTICES  dir with LICENSE.md, NOTICE and CITATION.cff for the viewer, as written by
#            tools/licences/licgen.py and published in its HF download repo
#            (chibifire/interactor-skintokens-viewer or chibifire/interactor-kimodo-motion-viewer).
#            Each package gets the three files at the top level: the MIT, BSD and Apache-2.0
#            parts require their notices to ship with the binaries, and the NVIDIA Open Model
#            License and the Meta Llama 3 licence require a NOTICE file. `package` stops if one
#            is missing.
#   BINTR    optional: dir with macos/, windows/ and linux/, each holding that OS's native
#            translations bintr-<HASH>.dylib, .dll or .so (tools/compile_bintr.sh); a package
#            without them runs every guest in the interpreter
# <w> holds mesh-encoder.gguf, skin-vae.gguf and tokenrig.gguf (skintokens), or
# Kimodo-SOMA-RP-v1.1-gguf/kimodo-soma-rp-v1.1.gguf (kimodo-motion, chibifire/Kimodo-SOMA-RP-v1.1-gguf).
# The pck is OS-independent; `package` runs anywhere with zip and tar (the Windows desk's WSL is
# fastest for the 1.3 GB archives). Archives store the weights uncompressed (zip -0 for .gguf).
set -eu
cmd=$1 out=$(cd "$2" 2>/dev/null && pwd || (mkdir -p "$2" && cd "$2" && pwd))
here=$(cd "$(dirname "$0")/.." && pwd)

if [ "$cmd" = pck ]; then
  # A second pck run into the same folder would overwrite this one's src mid-export.
  mkdir "$out/.pck.lock" 2>/dev/null || { echo "another pck build is using $out"; exit 1; }
  trap 'rmdir "$out/.pck.lock"' EXIT
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
  cp "$USD_ELF" "$src/usd.elf"
  cp "$MOTION_ELF" "$src/motion.elf"
  if [ -z "${HEADFIT_ELF:-}" ]; then
    repo=V-Sekai-fire/interactor-headfit
    run=$(gh run list -R "$repo" --workflow guest --branch "${HEADFIT_BRANCH:-main}" --status success \
      --limit 1 --json databaseId --jq '.[0].databaseId')
    [ -n "$run" ] || { echo "no green guest run on $repo ${HEADFIT_BRANCH:-main}"; exit 1; }
    name=$(gh api "repos/$repo/actions/runs/$run/artifacts" --jq '.artifacts[] | select(.name | startswith("headfit-elf-")) | .name' | head -1)
    rm -rf "$out/headfit-ci" && gh run download "$run" -R "$repo" -n "$name" -D "$out/headfit-ci"
    HEADFIT_ELF="$out/headfit-ci/headfit.elf"
    { echo "$repo run $run artifact $name"; cat "$out/headfit-ci/headfit.elf.siblings.txt"; } > "$out/headfit.elf.source.txt"
  fi
  # The double-precision viewer refuses a guest whose .sandbox_variant does not name a 40-byte Variant.
  python3 -c 'import sys; b = open(sys.argv[1], "rb").read(); sys.exit(0 if b"SBXV(\0\0\0" in b and b"hf_anime_shape\0" in b else 1)' \
    "$HEADFIT_ELF" || { echo "$HEADFIT_ELF is not a double-precision headfit.elf with hf_anime_shape"; exit 1; }
  cp "$HEADFIT_ELF" "$src/headfit.elf"
  cp "$MM_ELF" "$src/mm.elf"
  python3 -c 'import sys; b = open(sys.argv[1], "rb").read(); sys.exit(0 if b"SBXV(\0\0\0" in b and b"mjc_player_band\0" in b else 1)' \
    "$MUJOCO_ELF" || { echo "$MUJOCO_ELF is not a double-precision mujoco.elf with mjc_player_band"; exit 1; }
  cp "$MUJOCO_ELF" "$src/mujoco.elf"
  mkdir -p "$src/motion/mm"
  first=""
  for set in $(echo "$MM_DATA" | tr ':' ' '); do
    for d in "$set"/*/; do
      k=$(basename "$d")
      cp "$d/transforms.f32" "$src/motion/mm/$k.f32"
      [ ! -f "$d/phase.f32" ] || cp "$d/phase.f32" "$src/motion/mm/$k.phase.f32"
      fps=$(awk '/^frames / {print $4}' "$d/skeleton.txt")
      [ -n "$fps" ] || { echo "$d/skeleton.txt has no frame rate"; exit 1; }
      if [ -f "$d/loop.txt" ]; then kind=loop; else kind=once; fi
      printf '%s\t%s\t%s\n' "$k" "$kind" "$fps" >> "$src/motion/mm/clips.tsv"
      [ -n "$first" ] || first=$d
    done
  done
  sed -n '4,$p' "$first/skeleton.txt" > "$src/motion/mm/skeleton.txt"
  cp "$first/parents.txt" "$src/motion/mm/parents.txt"
  G="$ENGINE/godot.macos.editor.double.arm64"
  "$G" --headless --path "$src" --import > "$out/import.log" 2>&1 || true
  # lilToon (thirdparty/lilToon) as asset package members, carried by every exported package.
  "$G" --headless --path "$src" --script tools/liltoon_pack.gd > "$out/liltoon_pack.log" 2>&1 \
    || { cat "$out/liltoon_pack.log"; exit 1; }
  "$G" --headless --path "$src" --export-pack Linux "$out/skintokens-viewer.pck" > "$out/export.log" 2>&1
  if grep -q "SCRIPT ERROR" "$out/export.log"; then echo "SCRIPT ERROR in export.log"; exit 1; fi
  for f in skintokens.elf usd.elf motion.elf headfit.elf mm.elf liltoon.tar AssetPackageExport.sgd mujoco.elf colliders.json godot-riscv.gdextension AutoRig.gd FaceBlink.gd FaceRoles.gd UsdImport.gd Motion.gd MotionMatch.gd Bintr.gd clips.tsv walk.f32 mm/skeleton.txt; do
    grep -aq "$f" "$out/skintokens-viewer.pck" || { echo "pck lacks $f"; exit 1; }
  done
  echo "PCK-OK $(wc -c < "$out/skintokens-viewer.pck") bytes"
  exit 0
fi

[ "$cmd" = package ] || { sed -n 2,22p "$0"; exit 2; }
w=$3 variant=${4:-skintokens}
case $variant in
  skintokens) app=skintokens-viewer weights="mesh-encoder.gguf skin-vae.gguf tokenrig.gguf" ;;
  kimodo-motion) app=kimodo-motion-viewer weights="Kimodo-SOMA-RP-v1.1-gguf/kimodo-soma-rp-v1.1.gguf" ;;
  *) echo "unknown viewer $variant"; exit 2 ;;
esac
for f in $weights; do
  [ -f "$w/$f" ] || { echo "missing $w/$f"; exit 1; }
done
for f in LICENSE.md NOTICE CITATION.cff; do
  [ -f "${NOTICES:-}/$f" ] || { echo "missing \$NOTICES/$f (from the viewer's HF download repo)"; exit 1; }
done
lay() { # <os> <runtime> <exe suffix> <library>
  d="$out/$variant/$1/$app"
  rm -rf "$out/$variant/$1" && mkdir -p "$d/w"
  cp "$ENGINE/$2" "$d/$app$3" && chmod +x "$d/$app$3"
  # Godot loads the pck that has the name of the program.
  cp "$out/skintokens-viewer.pck" "$d/$app.pck"
  cp -R "$SANDBOX/$4" "$d/"
  cp "$ENGINE/LICENSE-model-explorer.txt" "$d/"
  cp "$NOTICES/LICENSE.md" "$NOTICES/NOTICE" "$NOTICES/CITATION.cff" "$d/"
  for f in $weights; do
    mkdir -p "$d/w/$(dirname "$f")" && cp "$w/$f" "$d/w/$f"
  done
  if [ -n "${BINTR:-}" ]; then
    mkdir -p "$d/bintr" && cp "$BINTR/$1"/bintr-* "$d/bintr/"
  fi
}
lay macos godot.macos.template_release.double.arm64 "" \
  libgodot_riscv.macos.template_release.double.universal.framework
lay windows godot.windows.template_release.double.x86_64.llvm.exe .exe \
  libgodot_riscv.windows.template_release.double.x86_64.dll
lay linux godot.linuxbsd.template_release.double.x86_64 "" \
  libgodot_riscv.linux.template_release.double.x86_64.so
# Archives hold the files at the top level: Explorer and Archive Utility already extract into a folder
# named after the archive, so a top folder inside it would give <app>-*/<app>/.
o="$out/$variant"
rm -f "$o/$app"-*.zip "$o/$app"-*.tar
(cd "$o/macos/$app" && zip -qry -n .gguf "$o/$app-macos-arm64.zip" .)
(cd "$o/windows/$app" && zip -qr -n .gguf "$o/$app-windows-x86_64.zip" .)
(cd "$o/linux/$app" && tar -cf "$o/$app-linux-x86_64.tar" -- *)
(cd "$o" && sha256sum "$app"-*.zip "$app"-*.tar > SHA256SUMS 2>/dev/null \
  || shasum -a 256 "$app"-*.zip "$app"-*.tar > SHA256SUMS)
cat "$o/SHA256SUMS"
echo PACKAGE-OK
