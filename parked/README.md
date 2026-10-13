# Parked 2026-10-13

Work from the SkinTokens Space session that has no repository of its own yet. RFD 2314 in
manuals-weftspun (PR 291) records the decisions; this branch holds the files.

- `tests/`: the browser checks run against the Space.
  - `drop_test.mjs <url> <glb> <out.png>`: drop a file, screenshot before and after, console log.
  - `tools_test.mjs <url> <glb|x> <out.png>`: press G, E and W and screenshot each.
  - `dark_check.mjs <url> <prefix>` and `dark_frac.py <prefix>`: never-black check.
  - `load_time.mjs`, `load_warm.mjs`, `load_prof.mjs`: cold and warm load timing, CPU profile.
  - `me-fork-build.sh`, `space-upload.py`, `coi_server.py`, `tscn2gd.py`: build, publish, serve.
- `console/`: the console page project settings (light background, dark text).
- `starforged-character/`: the Starforged sample woman. ANNY body (SOMA topology and rig),
  MakeHuman CC0 sports suit tinted slate (no MakeHuman brand colours), shoes03, ponytail01,
  young light skin. `build_spacer.py` needs the anny checkout and the MakeHuman CC0 asset pack
  (`NOTES.md` has the URL and hash). `spacer.glb` is the output.

## Load time (measured on the Mac mini, Chrome, local server)

| Step                                   | Cold    | Warm   |
| -------------------------------------- | ------- | ------ |
| Downloads done (65 MB, no compression) | 2.4 s   | 0.5 s  |
| Engine start to Boot ready             | 3.7 s   | 0.15 s |
| Build Model Explorer from guests       | 3.0 s   | 2.3 s  |
| Tree, materials, first frame           | 3.5 s   | 0.7 s  |
| Sample loaded                          | 12.6 s  | 3.75 s |

Warm means the second visit, with Godot's shader cache in the browser's storage. The cold
profile spends 7.2 s of the main thread in `condition_variable::wait`, waiting on shader
compiles (GLSL to SPIR-V to WGSL with tint, in wasm).

Next, in order:
1. Shader baker for WebGPU: an `editor/shader/shader_baker/..._platform_webgpu` plugin that
   uses `RenderingShaderContainerFormatWebGpu`, so export bakes WGSL into the pck. Needs the
   container and tint built into the macOS editor (today the driver is web only).
2. Ship zstd-compressed files and decompress in the page: 65 MB becomes about 17 MB
   (side.wasm 42.4 to 9.0 MB, pck 16.7 to 5.7 MB). HF serves them uncompressed.
3. Guest build of Model Explorer: 2.3 s even warm; profile the 45 `.sgd.elf` loads.
Quest 3 is slower than the Mac; none of this is measured on it.
