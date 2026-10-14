# Model Explorer as godot-sandbox guests

This branch runs Model Explorer with no GDScript and no scene files in the export. Every script
is a RISC-V program (`.sgd.elf`) that godot-sandbox runs, and every scene is a build procedure
compiled into one of those programs. It is the viewer of the chibifire SkinTokens Space.

## Build

Needs: the compiler from V-Sekai-fire/entities-godot-sandbox-gdscript-compiler
(`pixi run cmake --build build --target gdscript_to_riscv`), the godot-sandbox addon
(`addons/godot_sandbox` with the double-precision threaded web library), a Godot editor and a
threaded double-precision web export template with WebGPU.

```sh
python3 guest/build.py <work dir> <gdscript_to_riscv> <addons/godot_sandbox> <web template zip>
godot --headless --path <work dir> --import
godot --headless --path <work dir> --export-release Web out/index.html
```

## What the build changes

- `tscn2gd.py` turns each `.tscn` into `<Name>_scene.gd` with `func instantiate()`, and rewrites
  `preload("...tscn")` users to `X.new().instantiate()`.
- `overlay/boot.tscn` is the main scene, an empty Node; the `Boot` autoload (`overlay/boot.gd`)
  builds Model Explorer, gives it a light studio (a backdrop quad, colour ambient light), loads
  the sample model and shows a one-line hint.
- Relative `load`/`preload` paths become `res://` paths: the guest passes the literal string to
  the host.
- On the web: Mobile renderer, no 2D MSAA, no physical light units.

## Shader warm-up (export pipeline only)

When the page args contain `--warmup` (copy `index.html` to `warmup.html` with
`"args":["--warmup"]`), `boot.gd` draws one small sphere per StandardMaterial3D shader key the glTF
importer produces, waits 30 frames, prints every file under `user://shader_cache` as
`SCF <path> <part> <parts> <hex>` console lines, then prints `WARMUP done`. A harvester joins the
lines back into files. Normal visits never pass `--warmup`, so they do not run this code.

`overlay/sample/mire.glb`: Mille "Mire" Feuille by Mohka Noir, Apache-2.0, converted from MireQuest.blend (see `overlay/sample/NOTICE.txt`). Sample models must allow commercial use and must not be share-alike.
