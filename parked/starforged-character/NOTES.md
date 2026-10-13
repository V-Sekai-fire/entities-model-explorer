# ANNY-soma-x woman, dressed in MakeHuman CC0 clothes

Local only. Nothing was published or pushed.

## Outputs

| File | Bytes | Notes |
|---|---|---|
| `woman.glb` | 5,215,308 | sha256 `505043af85a80d7b457cb2af567c464435659afc801d039b167664b7e788c148` |
| `preview.png` | 1,006,601 | Blender 5.2.2 Cycles, front 3/4 view (35°), 900×1200 |
| `skin_baked_soma_uv.png` | 3,549,774 | MakeHuman light skin baked into SOMA UVs, 2048² (the GLB embeds it as a JPEG) |
| `build_stats.json` | | All the numbers below, written by `build.py` |
| `checks/close_{face,legs,torso,back}.png`, `checks/posed.png` | | Visual checks |
| `godot_check/load_glb.gd`, `godot_check/woman_truncated.glb` | | The Godot load check and its truncated control |

## What "ANNY-soma-x" means here

`anny.Anny(rig="soma", topology="soma", phenotypes="all")`, from `3-interactor/anny` commit `fed2f9a2` (working tree clean). In `src/anny/models/soma.py` this is the ANNY body retopologised onto the SOMA mesh (`data/soma/SOMA_wrap.obj`), using the canonical SOMA-X triangulation (`soma_faces.pt`) and the SOMA rig (`soma_rig.pt`). That gives 18,056 vertices, 36,108 triangles and 78 joints (Root, Hips, Spine1…, LeftEye/RightEye, fingers, toes). `examples/soma_comparison.py` builds the same configuration. SMPL and SMPL-X were not used.

## Phenotype

```
gender=1.0  age=0.72  muscle=0.5  weight=0.5  height=0.5  proportions=0.5
cupsize=0.5 firmness=0.5  african=0.0 asian=0.0 caucasian=1.0
```

- **Gender: 1.0 is female in this checkout.** The brief said "0 = female", but `model_data.py` defines `PHENOTYPE_VARIATIONS["gender"] = ["male", "female"]` on anchors `linspace(0,1)`. A geometry probe (`env/probe3.py`) confirms it: gender 0 gives 1.92 m tall with 0.57 m shoulders, and gender 1 gives 1.78 m with 0.47 m shoulders.
- **Age:** the anchors are newborn/baby/child/young/old at −1/3, 0, 1/3, 2/3, 1. So 0.72 is just past "young" (25 y). If the 25→90 y span is linear, that is roughly 35 years old. This is my reading of the anchors; I did not measure it.
- **Race:** caucasian=1, with the light-skin texture below.
- **Result:** standing height 1.78 m, bind pose = ANNY rest pose (MakeHuman-style A-pose).

## Assets, sources, licences

All assets come from **MakeHuman 1.x system assets, CC0 1.0**:

- URL: `https://files.makehumancommunity.org/asset_packs/makehuman_system_assets/makehuman_system_assets_cc0.zip`
- Size: 280,737,770 B, sha256 `b542127a8e25547c7c29c19f2d1d2adb9a664c80396ecd694095dbc8028a0107`
- Licence: every `.mhclo`/`.mhmat` header says "explicitly released as CC0 in september 2020" (copyright holders Data Collection AB, Joel Palmius, Jonas Hauquier). `packs/makehuman_system_assets.json` in the zip lists `"license": "CC0"` for each asset.
- The old `github.com/makehumancommunity/makehuman-assets` repository returns 404, so this asset pack was used instead.

| Item | Asset | Files used |
|---|---|---|
| Clothing 1: blue T-shirt + jeans (one asset) | `clothes/female_casualsuit01` | .mhclo, .obj, diffuse, normal (4096 downscaled to 2048) |
| Clothing 2: sneakers with socks | `clothes/shoes06` | .mhclo, .obj, diffuse |
| Eyes (not clothing, added so the sockets aren't empty) | `eyes/high-poly` + `eyes/materials/brown.mhmat` | brown_eye.png, alpha blend |
| Eyebrows (not clothing) | `eyebrows/eyebrow001` | eyebrow001.png, alpha mask |
| Skin | `skins/middleage_caucasian_female` | `middleage_lightskinned_female_diffuse.png` |

The ANNY code is Apache-2.0 (NAVER). ANNY's bundled MakeHuman/MPFB2 data (`base.obj` UVs, targets) is CC0 (`data/mpfb2/LICENSE.md`).

## Method (`build.py`)

1. **Two ANNY models, same phenotype.** One is the SOMA rig and topology. The other is `rig="anny"` with the full MakeHuman topology (`remove_unattached_vertices=False`), so all 19,158 hm08 vertices are kept, including the helper vertices that `.mhclo` files reference (e.g. the tights helper). The two rest meshes coincide: MakeHuman body vertices lie within 0.52 mm (mean), 3.0 mm (p99) and 7.3 mm (max) of the SOMA surface.
2. **Fitting with the MakeHuman proxy algorithm.** Each clothing vertex is placed at `Σ wᵢ·V[refᵢ] + offset ⊙ scale`. The `x/y/z_scale` values come from the reference vertex pairs, measured in MakeHuman units: ANNY's `0.1·Rx(90°)` world transform is inverted, the fit is done, and the result is mapped back. This is a new fitter, about 30 lines. Grepping the workspace for `mhclo`/`makehuman`/`clothes` found no existing one (meshing-pen `dress_on.elf`/`make_skirt.gd` are not `.mhclo` fitters).
3. **Hiding body under clothes.** A SOMA vertex is hidden when its closest MakeHuman body triangle is entirely in the garments' `delete_verts`. This hides 5,657 vertices. Only triangles whose 3 vertices are all hidden are dropped: 24,915 of 36,108 are kept.
4. **Garment on garment.** Sock faces more than 2 cm above the jeans hem on the same leg are dropped (240 faces), because the socks showed through the jeans. An earlier "inside the outer garment" test also cut the sock band at the hem and left a dark gap, so it was removed.
5. **Skin texture.** Each texel of SOMA's own UV layout (from `SOMA_wrap.obj`; each triangle corner's UV is taken from its source quad) is mapped to a 3D point. That point is projected to the closest MakeHuman body triangle, and the MakeHuman light-skin texture is sampled at that triangle's UV. Empty gutters are filled with the nearest value.
6. **Skinning.** The body uses ANNY's SOMA weights (14 influences per vertex), reduced to the top 4 and renormalised. Each clothing, eye and eyebrow vertex takes the barycentric blend of the SOMA weights at its closest point on the body, then the top 4. Joints are the SOMA `rest_bone_poses`, with exactly orthonormal rotations (error 2e-15). inverseBindMatrices = inverse of those poses.
7. **Axes and export.** Converted from ANNY's frame (Z-up, front −Y) to glTF's (Y-up, front +Z, metres, feet at y=0). The GLB is written by hand (no extra dependencies): one skin and 5 meshes, each a separate node.

## Counts (glTF vertices are split at UV seams)

| Mesh | glTF verts | unique positions | triangles |
|---|---|---|---|
| body_anny_soma | 13,310 | 12,522 | 24,915 |
| female_casualsuit01 | 2,406 | 2,197 | 4,236 |
| shoes06 | 1,623 | 1,479 | 2,824 |
| high-poly (eyes) | 1,076 | 1,064 | 2,040 |
| eyebrow001 | 126 | 124 | 192 |

- Skeleton: 78 joints, 1 skin.
- Materials: `skin_light` (baked texture, roughness 0.6), suit (diffuse + normal), shoes (diffuse), eyes (BLEND), eyebrows (MASK 0.35, double-sided).

## Commands run

```sh
cd /Users/ernest.lee/.hermes/cache/scratch/anny-soma-woman
curl -sL -o src/makehuman_system_assets_cc0.zip https://files.makehumancommunity.org/asset_packs/makehuman_system_assets/makehuman_system_assets_cc0.zip
(cd src && unzip -q makehuman_system_assets_cc0.zip 'clothes/*' 'skins/middleage_caucasian_female/*' 'eyes/*' 'eyebrows/eyebrow001/*' 'packs/*')
(cd env && pixi install)        # env/pixi.toml: python 3.11, anny (editable, local path), torch, numpy, scipy, pillow, pygltflib
pixi run --manifest-path env/pixi.toml python build.py
blender -b -P render_blender.py -- woman.glb $PWD/preview.png 35
blender -b -P render_closeups.py -- woman.glb $PWD/checks/close
blender -b -P checks/pose_check.py -- woman.glb $PWD/checks/posed.png LeftArm:X:50 RightLeg:X:-40 LeftForeArm:Z:40 Head:Y:25
G=/Users/ernest.lee/.hermes/cache/scratch/godot-webgpu/bin/godot.macos.editor.arm64   # v4.8.dev f95b07f1b
python3 -c "b=open('woman.glb','rb').read(); open('godot_check/woman_truncated.glb','wb').write(b[:len(b)//2])"
$G --headless --script godot_check/load_glb.gd -- $PWD/woman.glb
$G --headless --script godot_check/load_glb.gd -- $PWD/godot_check/woman_truncated.glb
```

The anny pixi environment from `4-entities/anny-creator` only lists win-64 and linux-64, so a separate osx-arm64 pixi project is in `env/`.

## Checks

- **Godot load:** `RESULT loaded meshes=5 surfaces=5 bones=78 skins=1`, with names body_anny_soma, female_casualsuit01, shoes06, high-poly, eyebrow001. Exit 0.
- **Truncated control (first half of the file):** `ERROR: Condition "len != chunk_length" ... ERR_FILE_CORRUPT`, `RESULT refused err=16 (File corrupt)`. Exit 2.
- **Blender import:** 5 meshes plus an armature with 78 bones. Blender also adds an `Icosphere` bone-display shape, which is not in the GLB.
- **Visual (preview and close-ups):** the T-shirt, jeans and shoes sit on the body. There is no skin poking through, nothing floats, and the eyes and eyebrows are in place.
- **Posed check:** posing in Blender (arm, forearm, head, leg) moves the clothes, eyes and eyebrows with the body.
- **Fit numbers:**
  - suit: mean 5.4 mm / max 26 mm from the body; 2.2 % of its vertices within 1 cm are inside the *visible* body.
  - shoes: 0 % inside the visible body.
  - eyes: the "inside body" figure is high by design, because they sit in the sockets.

## Known problems

- She is bald. Hair was not requested, and MakeHuman hair would be one more `.mhclo`.
- 3,266 of 18,056 body vertices had more than 4 bone influences, and these were cut to 4. Deformation may differ slightly from ANNY's own LBS at extreme poses.
- The body faces under the T-shirt and jeans are deleted (MakeHuman `delete_verts` behaviour), so the body cannot be shown without the clothes.
- Clothes are rigidly skinned, with no cloth correctives. The jeans can clip at extreme hip or knee bends.
- The skin is baked across topologies, so it is slightly soft at SOMA UV seams. The face texture is soft compared with native MakeHuman.
- The suit's AO map and the skin's SSS/litsphere parameters were not carried over; plain PBR is used.
- **Godot crash:** calling `GLTFDocument.append_from_file` directly from `SceneTree._init()` in `--headless` crashes Godot 4.8.dev (signal 11). Deferring the call to the first frame (`_run.call_deferred()`) works. That is what `load_glb.gd` does.
