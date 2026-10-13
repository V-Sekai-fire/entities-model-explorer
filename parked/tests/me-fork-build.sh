#!/bin/bash
# Build Model Explorer as guests from the V-Sekai-fire fork checkout (dev/guest) and export it.
S=~/.hermes/cache/scratch
F=$S/me-fork
C=~/Desktop/chibifire-smoke-water/4-entities/godot-sandbox-gdscript-compiler/build/src/gdscript/compiler/gdscript_to_riscv
G=$S/godot-webgpu/bin/godot.macos.editor.arm64
T=$S/godot-webgpu/bin/godot.web.template_release.double.wasm32.dlink.zip
W=$S/model-explorer-sgd
python3 $F/guest/build.py $W $C $S/godot-sandbox/bin/addons/godot_sandbox $T > $S/me-compile.log 2>&1
echo compile=$?; tail -1 $S/me-compile.log; grep '^BAD' $S/me-compile.log | head
cd $W || exit 1
timeout 280 $G --headless --path . --import > import.log 2>&1
mkdir -p out
timeout 280 $G --headless --path . --export-release "Web" out/index.html > export.log 2>&1
echo export=$?
rm -f out/index.png
