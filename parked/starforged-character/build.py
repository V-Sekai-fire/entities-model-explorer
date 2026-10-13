"""Build woman.glb: ANNY body in SOMA-X topology + rig (anny.Anny(rig="soma", topology="soma")),
dressed with MakeHuman CC0 system clothes fitted via their .mhclo reference triangles on the
full MakeHuman-topology ANNY mesh (same phenotype, same rest frame), skinned to the SOMA rig.

Run: pixi run --manifest-path env/pixi.toml python build.py
"""
import json, math, os, re, struct, io, sys
import numpy as np
import torch
from PIL import Image
from scipy import ndimage
import roma
import anny
from anny.paths import get_anny_root_dir
from anny.models.model_data import TopologyConfig
from anny.utils.warp_mesh_utils import point_to_mesh_distance_and_face_uvs

torch.set_grad_enabled(False)
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
OUT = os.path.join(HERE, "woman.glb")
ANNY_DATA = os.path.join(get_anny_root_dir(), "data")
DT = torch.float64

# ANNY: gender anchors are PHENOTYPE_VARIATIONS["gender"] = ["male", "female"] on linspace(0, 1),
# so in this anny checkout gender=1.0 is female (verified by geometry in probe3.py).
PHENOTYPE = dict(gender=1.0, age=0.72, muscle=0.5, weight=0.5, height=0.5, proportions=0.5,
                 cupsize=0.5, firmness=0.5, african=0.0, asian=0.0, caucasian=1.0)
CLOTHES = ["female_casualsuit01", "shoes06"]
# (kind, asset dir relative to src/, mhclo stem, material file relative to src/)
ASSETS = [("clothes", "clothes/female_casualsuit01", "female_casualsuit01", "clothes/female_casualsuit01/female_casualsuit01.mhmat"),
          ("clothes", "clothes/shoes06", "shoes06", "clothes/shoes06/shoes06.mhmat"),
          ("eyes", "eyes/high-poly", "high-poly", "eyes/materials/brown.mhmat"),
          ("eyebrows", "eyebrows/eyebrow001", "eyebrow001", "eyebrows/eyebrow001/eyebrow001.mhmat")]
SKIN = ("middleage_caucasian_female", "middleage_lightskinned_female_diffuse.png")
TEX = 2048


def log(*a):
    print(*a, flush=True)


# ---------------------------------------------------------------- OBJ / MHCLO parsing
def parse_obj(path):
    V, VT, faces, groups = [], [], [], []
    g = None
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("v "):
            V.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("vt "):
            VT.append([float(x) for x in line.split()[1:3]])
        elif line.startswith("g "):
            g = line.split(None, 1)[1].strip()
        elif line.startswith("f "):
            vs, ts = [], []
            for tok in line.split()[1:]:
                p = tok.split("/")
                vs.append(int(p[0]) - 1)
                ts.append(int(p[1]) - 1 if len(p) > 1 and p[1] else -1)
            faces.append((vs, ts))
            groups.append(g)
    return np.array(V), np.array(VT), faces, groups


def tri_fan(faces):
    tv, tt = [], []
    for vs, ts in faces:
        for i in range(1, len(vs) - 1):
            tv.append([vs[0], vs[i], vs[i + 1]])
            tt.append([ts[0], ts[i], ts[i + 1]])
    return np.array(tv, np.int64), np.array(tt, np.int64)


def parse_mhclo(path):
    refs, scales, delete, mode = [], {}, [], None
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        tok = line.split()
        if tok[0] in ("x_scale", "y_scale", "z_scale"):
            scales[tok[0][0]] = (int(tok[1]), int(tok[2]), float(tok[3]))
        elif tok[0] == "verts":
            mode = "verts"
        elif tok[0] == "delete_verts":
            mode = "delete"
        elif mode == "verts" and re.match(r"^-?\d", tok[0]):
            if len(tok) == 1:
                refs.append(([int(tok[0])] * 3, [1.0, 0.0, 0.0], [0.0, 0.0, 0.0]))
            else:
                refs.append(([int(t) for t in tok[0:3]], [float(t) for t in tok[3:6]], [float(t) for t in tok[6:9]]))
        elif mode == "delete" and re.match(r"^\d", tok[0]):
            i = 0
            while i < len(tok):
                if i + 2 < len(tok) and tok[i + 1] == "-":
                    delete.extend(range(int(tok[i]), int(tok[i + 2]) + 1)); i += 3
                else:
                    delete.append(int(tok[i])); i += 1
    return refs, scales, np.array(sorted(set(delete)), np.int64)


def parse_mhmat(path):
    d = {}
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.split("#", 1)[0].strip()
        if line:
            k, *v = line.split(None, 1)
            d[k] = v[0] if v else ""
    return d


def closest(points, verts, faces):
    d, fid, uv = point_to_mesh_distance_and_face_uvs(
        points=torch.tensor(np.asarray(points), dtype=torch.float32),
        vertices=torch.tensor(np.asarray(verts), dtype=torch.float32),
        faces=torch.tensor(np.asarray(faces), dtype=torch.int64), max_dist=10.0)
    u, v = uv[:, 0].numpy().astype(np.float64), uv[:, 1].numpy().astype(np.float64)
    # anny convention (soma.py / probe2): bary = [u, v, 1-u-v] on face corners [0, 1, 2]
    return d.numpy(), fid.numpy(), np.stack([u, v, 1 - u - v], 1)


def vertex_normals(V, F):
    n = np.zeros_like(V)
    fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    for k in range(3):
        np.add.at(n, F[:, k], fn)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    return n


def top4(dense):
    idx = np.argsort(-dense, axis=1)[:, :4]
    w = np.take_along_axis(dense, idx, 1)
    w = w / np.maximum(w.sum(1, keepdims=True), 1e-12)
    return idx.astype(np.uint16), w.astype(np.float32)


# ---------------------------------------------------------------- 1. bodies
log("building ANNY models (soma rig+topology, and full makehuman topology for fitting)")
soma = anny.Anny(rig="soma", topology="soma", phenotypes="all").to(dtype=DT)
tc = TopologyConfig(base_mesh="makehuman", submodel="body", nudity_edits=False, eyes=True, tongue=True,
                    remove_unattached_vertices=False, triangulate_faces=True)
mh = anny.Anny(rig="anny", topology=tc, phenotypes="all").to(dtype=DT)


def run(m):
    B = len(m.bone_labels)
    pose = torch.eye(4, dtype=DT)[None, None].repeat(1, B, 1, 1)
    return m(pose_parameters=pose, phenotype_kwargs=PHENOTYPE)


os_ = run(soma)
SV = os_["rest_vertices"][0].numpy()             # (18056,3) anny frame: Z-up, metres, front -Y
SB = os_["rest_bone_poses"][0].numpy()           # (78,4,4) world bone frames, bind pose
MV = run(mh)["rest_vertices"][0].numpy()         # (19158,3) incl. MakeHuman helper vertices
SF = soma.faces.numpy().astype(np.int64)
assert MV.shape[0] == 19158, MV.shape
log("soma verts", SV.shape, "faces", SF.shape, "bones", len(soma.bone_labels))

# anny world transform for the MakeHuman base mesh: anny = 0.1 * Rx(90) @ mh  (full_model.py)
R = roma.euler_to_rotmat("X", [90.0], degrees=True, dtype=torch.float64).numpy().reshape(3, 3)
MV_mh = (MV @ R) / 0.1                            # back into MakeHuman units/frame (dm, Y-up)
baseV, baseVT, baseF, baseG = parse_obj(os.path.join(ANNY_DATA, "mpfb2/3dobjs/base.obj"))
assert baseV.shape[0] == 19158
body_faces = [f for f, g in zip(baseF, baseG) if g == "body"]
mhF, mhFT = tri_fan(body_faces)
log("makehuman body tris", mhF.shape)
d, _, _ = closest(MV[:13380], SV, SF)
log("MH body verts -> SOMA surface distance: mean %.4f m, p99 %.4f m, max %.4f m" % (d.mean(), np.percentile(d, 99), d.max()))
STATS = {"mh_to_soma_mean_m": float(d.mean()), "mh_to_soma_p99_m": float(np.percentile(d, 99)),
         "mh_to_soma_max_m": float(d.max())}

# ---------------------------------------------------------------- 2. SOMA UVs per triangle corner
sV, sVT, sFaces, _ = parse_obj(os.path.join(ANNY_DATA, "soma/SOMA_wrap.obj"))
assert sV.shape[0] == SV.shape[0]
v2poly = {}
for pi, (vs, ts) in enumerate(sFaces):
    for v in vs:
        v2poly.setdefault(v, []).append(pi)
SFT = np.zeros_like(SF)
for ti, (a, b, c) in enumerate(SF):
    cand = [p for p in v2poly[a] if b in sFaces[p][0] and c in sFaces[p][0]]
    assert cand, ti
    vs, ts = sFaces[cand[0]]
    SFT[ti] = [ts[vs.index(a)], ts[vs.index(b)], ts[vs.index(c)]]
log("soma uv corners resolved", SFT.shape, "vt", sVT.shape)

# ---------------------------------------------------------------- 3. bake MakeHuman light skin into SOMA UVs
skin_img = np.asarray(Image.open(os.path.join(SRC, "skins", SKIN[0], SKIN[1])).convert("RGB")).astype(np.float32)
H_, W_ = skin_img.shape[:2]
pix_xyz, pix_id = [], []
uvp = sVT[SFT] * TEX                               # (T,3,2) in pixel units (v up)
for ti in range(SF.shape[0]):
    p = uvp[ti]
    x0, y0 = np.floor(p.min(0)).astype(int); x1, y1 = np.ceil(p.max(0)).astype(int)
    xs, ys = np.meshgrid(np.arange(max(x0, 0), min(x1 + 1, TEX)), np.arange(max(y0, 0), min(y1 + 1, TEX)))
    q = np.stack([xs.ravel() + 0.5, ys.ravel() + 0.5], 1)
    T = np.array([p[1] - p[0], p[2] - p[0]]).T
    if abs(np.linalg.det(T)) < 1e-12:
        continue
    l12 = np.linalg.solve(T, (q - p[0]).T).T
    bc = np.c_[1 - l12.sum(1), l12]
    ok = (bc > -1e-3).all(1)
    if not ok.any():
        continue
    bc = bc[ok]; q = q[ok].astype(int)
    pix_xyz.append(bc @ SV[SF[ti]])
    pix_id.append((TEX - 1 - q[:, 1]) * TEX + q[:, 0])  # row from top
pix_xyz = np.concatenate(pix_xyz); pix_id = np.concatenate(pix_id)
_, fid, bc = closest(pix_xyz, MV, mhF)
mh_uv = np.einsum("nk,nkc->nc", bc, baseVT[mhFT[fid]])
sx = np.clip(mh_uv[:, 0] * W_ - 0.5, 0, W_ - 1); sy = np.clip((1 - mh_uv[:, 1]) * H_ - 0.5, 0, H_ - 1)
cols = np.stack([ndimage.map_coordinates(skin_img[..., c], [sy, sx], order=1) for c in range(3)], 1)
bake = np.zeros((TEX * TEX, 3), np.float32); mask = np.zeros(TEX * TEX, bool)
bake[pix_id] = cols; mask[pix_id] = True
bake = bake.reshape(TEX, TEX, 3); mask = mask.reshape(TEX, TEX)
_, (iy, ix) = ndimage.distance_transform_edt(~mask, return_indices=True)
bake = bake[iy, ix]
Image.fromarray(np.clip(bake, 0, 255).astype(np.uint8)).save(os.path.join(HERE, "skin_baked_soma_uv.png"))
log("baked skin texels", int(mask.sum()))

# ---------------------------------------------------------------- 4. fit clothes (MakeHuman proxy algorithm)
def fit_clothes(kind, rel, name, matrel):
    d = os.path.join(SRC, rel)
    refs, scales, delete = parse_mhclo(os.path.join(d, name + ".mhclo"))
    cV, cVT, cF, _ = parse_obj(os.path.join(d, name + ".obj"))
    assert len(refs) == cV.shape[0], (name, len(refs), cV.shape)
    idx = np.array([r[0] for r in refs]); w = np.array([r[1] for r in refs]); off = np.array([r[2] for r in refs])
    scl = np.ones(3)
    for ax, k in (("x", 0), ("y", 1), ("z", 2)):
        if ax in scales:
            a, b, den = scales[ax]
            scl[k] = abs(MV_mh[a, k] - MV_mh[b, k]) / den
    P_mh = np.einsum("nk,nkc->nc", w, MV_mh[idx]) + off * scl
    P = 0.1 * P_mh @ R.T                           # to anny frame
    tv, tt = tri_fan(cF)
    mat = parse_mhmat(os.path.join(SRC, matrel)); matdir = os.path.dirname(os.path.join(SRC, matrel))
    return dict(kind=kind, matdir=matdir, name=name, V=P, VT=cVT, F=tv, FT=tt, delete=delete, mat=mat, dir=d, scale=scl)


garments = [fit_clothes(*a) for a in ASSETS]
for g in garments:
    log("fitted", g["name"], "verts", g["V"].shape[0], "tris", g["F"].shape[0], "scale", g["scale"].round(3))

# hide body under clothes: SOMA vertex removed if its closest MakeHuman body triangle is fully deleted
deleted = np.zeros(19158, bool)
for g in garments:
    deleted[g["delete"]] = True
_, fidS, _ = closest(SV, MV, mhF)
s_del = deleted[mhF[fidS]].all(1)
keepF = ~s_del[SF].all(1)
log("SOMA verts hidden", int(s_del.sum()), "faces kept", int(keepF.sum()), "/", SF.shape[0])

# skin weights
NB = len(soma.bone_labels)
sw_dense = np.zeros((SV.shape[0], NB))
vbi = soma.vertex_bone_indices.numpy(); vbw = soma.vertex_bone_weights.numpy()
np.add.at(sw_dense, (np.repeat(np.arange(SV.shape[0]), vbi.shape[1]), vbi.ravel()), vbw.ravel())
STATS["soma_verts_with_more_than_4_influences"] = int(((sw_dense > 1e-6).sum(1) > 4).sum())
for g in garments:
    dist, fid, bc = closest(g["V"], SV, SF)
    g["dense"] = np.einsum("nk,nkb->nb", bc, sw_dense[SF[fid]])
    g["body_dist"] = dist
    # penetration check: signed side wrt body normal at closest point
    nrm = vertex_normals(SV, SF)
    cp = np.einsum("nk,nkc->nc", bc, SV[SF[fid]]); cn = np.einsum("nk,nkc->nc", bc, nrm[SF[fid]])
    side = np.einsum("nc,nc->n", g["V"] - cp, cn)
    g["inside_frac"] = float((side < -1e-4).mean())
    log(g["name"], "dist to body mean %.4f max %.4f, verts inside body %.1f%%" % (dist.mean(), dist.max(), 100 * g["inside_frac"]))

# garment-on-garment: shoe (sock) faces that lie inside the outer garment would show through it;
# drop faces of the inner garment whose vertices are all inside the outer one (MakeHuman z_depth: higher = outer).
zd = {}
for g in garments:
    for raw in open(os.path.join(g["dir"], g["name"] + ".mhclo")):
        if raw.startswith("z_depth"):
            zd[g["name"]] = float(raw.split()[1])
clothes_g = [g for g in garments if g["kind"] == "clothes"]
for inner in clothes_g:
    inner["keepF"] = np.ones(inner["F"].shape[0], bool)
    for outer in clothes_g:
        if zd.get(outer["name"], 0) <= zd.get(inner["name"], 0):
            continue
        on = vertex_normals(outer["V"], outer["F"])
        dist, fid, bc = closest(inner["V"], outer["V"], outer["F"])
        cp = np.einsum("nk,nkc->nc", bc, outer["V"][outer["F"][fid]])
        cn = np.einsum("nk,nkc->nc", bc, on[outer["F"][fid]])
        inside = (np.einsum("nc,nc->n", inner["V"] - cp, cn) < 0.002) & (dist < 0.05)
        # also: anything of the inner garment higher than 2 cm above the outer garment's hem on the same
        # side of the body is covered by it (sock tops under jeans legs); hem = lowest outer vertex per side
        side_in = np.sign(inner["V"][:, 0]); side_out = np.sign(outer["V"][:, 0])
        hem = {s_: outer["V"][side_out == s_, 2].min() for s_ in (-1.0, 1.0)}
        above = np.array([z > hem.get(s_, np.inf) + 0.02 for z, s_ in zip(inner["V"][:, 2], side_in)])
        inside = above  # height rule only: the inside-test also removed the sock band right at the hem (dark gap)
        drop = inside[inner["F"]].all(1)
        inner["keepF"] &= ~drop
        log("%s faces inside %s dropped: %d" % (inner["name"], outer["name"], int(drop.sum())))
        STATS.setdefault("garment_faces_dropped_inside_outer", {})[f'{inner["name"]} in {outer["name"]}'] = int(drop.sum())
    inner["F"] = inner["F"][inner["keepF"]]; inner["FT"] = inner["FT"][inner["keepF"]]

# poke-through metric against the *visible* body only
nrmS = vertex_normals(SV, SF)
visF = SF[keepF]
for g in garments:
    dist, fid, bc = closest(g["V"], SV, visF)
    cp = np.einsum("nk,nkc->nc", bc, SV[visF[fid]]); cn = np.einsum("nk,nkc->nc", bc, nrmS[visF[fid]])
    near = dist < 0.01
    g["inside_visible_frac"] = float(((np.einsum("nc,nc->n", g["V"] - cp, cn) < -1e-4) & near).mean())
    log(g["name"], "verts inside the visible body within 1 cm: %.2f%%" % (100 * g["inside_visible_frac"]))

# ---------------------------------------------------------------- 5. coordinate change to glTF (Y-up, +Z front, feet at 0)
C = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)   # (x,y,z)_anny -> (x, z, -y)
floor = (SV @ C.T)[:, 1].min()
Cm = np.eye(4); Cm[:3, :3] = C; Cm[1, 3] = -floor


def to_gltf(P):
    return P @ C.T + Cm[:3, 3]


# ---------------------------------------------------------------- 6. GLB writer
class GLB:
    def __init__(self):
        self.bin = bytearray(); self.j = {"asset": {"version": "2.0", "generator": "anny-soma-woman build.py"},
                                          "buffers": [], "bufferViews": [], "accessors": [], "meshes": [],
                                          "materials": [], "textures": [], "images": [], "samplers": [{}],
                                          "nodes": [], "skins": [], "scenes": [{"nodes": []}], "scene": 0}

    def view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin += b"\0"
        bv = {"buffer": 0, "byteOffset": len(self.bin), "byteLength": len(data)}
        if target:
            bv["target"] = target
        self.bin += data
        self.j["bufferViews"].append(bv)
        return len(self.j["bufferViews"]) - 1

    def acc(self, arr, typ, ctype, target=None, minmax=False):
        arr = np.ascontiguousarray(arr)
        a = {"bufferView": self.view(arr.tobytes(), target), "componentType": ctype, "count": int(arr.shape[0]), "type": typ}
        if minmax:
            a["min"] = arr.min(0).tolist(); a["max"] = arr.max(0).tolist()
        self.j["accessors"].append(a)
        return len(self.j["accessors"]) - 1

    def image(self, img, fmt):
        b = io.BytesIO()
        if fmt == "jpeg":
            img.convert("RGB").save(b, "JPEG", quality=92)
        else:
            img.save(b, "PNG", optimize=True)
        self.j["images"].append({"bufferView": self.view(bytes(b.getvalue())), "mimeType": "image/" + fmt})
        self.j["textures"].append({"sampler": 0, "source": len(self.j["images"]) - 1})
        return len(self.j["textures"]) - 1

    def write(self, path):
        while len(self.bin) % 4:
            self.bin += b"\0"
        self.j["buffers"] = [{"byteLength": len(self.bin)}]
        for k in ("skins", "textures", "images"):
            if not self.j[k]:
                del self.j[k]
        js = json.dumps(self.j, separators=(",", ":")).encode()
        js += b" " * ((4 - len(js) % 4) % 4)
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total))
            f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
            f.write(struct.pack("<II", len(self.bin), 0x004E4942)); f.write(self.bin)


glb = GLB()
J = glb.j


def add_mesh(name, V, VT, F, FT, dense, material):
    """Split vertices on (position, uv) pairs, write a skinned primitive; returns stats."""
    N = vertex_normals(V, F)
    pairs = np.stack([F.ravel(), FT.ravel()], 1)
    uniq, inv = np.unique(pairs, axis=0, return_inverse=True)
    vi, ti = uniq[:, 0], uniq[:, 1]
    pos = to_gltf(V[vi]).astype(np.float32)
    nrm = (N[vi] @ C.T).astype(np.float32)
    uv = np.c_[VT[ti, 0], 1.0 - VT[ti, 1]].astype(np.float32)
    jn, wt = top4(dense[vi])
    idx = inv.reshape(-1).astype(np.uint32)
    attrs = {"POSITION": glb.acc(pos, "VEC3", 5126, 34962, True), "NORMAL": glb.acc(nrm, "VEC3", 5126, 34962),
             "TEXCOORD_0": glb.acc(uv, "VEC2", 5126, 34962), "JOINTS_0": glb.acc(jn, "VEC4", 5123, 34962),
             "WEIGHTS_0": glb.acc(wt, "VEC4", 5126, 34962)}
    J["meshes"].append({"name": name, "primitives": [{"attributes": attrs, "indices": glb.acc(idx, "SCALAR", 5125, 34963), "material": material, "mode": 4}]})
    J["nodes"].append({"name": name, "mesh": len(J["meshes"]) - 1, "skin": 0})
    return {"vertices_gltf": int(pos.shape[0]), "vertices_unique_positions": int(len(np.unique(vi))), "triangles": int(F.shape[0])}


# materials
skin_tex = glb.image(Image.fromarray(np.clip(bake, 0, 255).astype(np.uint8)), "jpeg")
J["materials"].append({"name": "skin_light", "pbrMetallicRoughness": {"baseColorTexture": {"index": skin_tex}, "baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.0, "roughnessFactor": 0.6}})
for g in garments:
    m = {"name": g["name"], "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.0, "roughnessFactor": 0.85}}
    if "diffuseTexture" in g["mat"]:
        im = Image.open(os.path.join(g["matdir"], g["mat"]["diffuseTexture"]))
        has_alpha = im.mode == "RGBA" and np.asarray(im)[..., 3].min() < 250
        m["pbrMetallicRoughness"]["baseColorTexture"] = {"index": glb.image(im, "png" if has_alpha else "jpeg")}
        if has_alpha and g["kind"] == "eyebrows":
            m["alphaMode"] = "MASK"; m["alphaCutoff"] = 0.35; m["doubleSided"] = True
        if g["kind"] == "eyes":
            m["pbrMetallicRoughness"]["roughnessFactor"] = 0.15
            if has_alpha:  # MakeHuman eye = eyeball + cornea shell; the shell is transparent in the texture
                m["alphaMode"] = "BLEND"
    if "normalmapTexture" in g["mat"]:
        im = Image.open(os.path.join(g["matdir"], g["mat"]["normalmapTexture"])).convert("RGB")
        if im.size[0] > 2048:
            im = im.resize((2048, 2048), Image.LANCZOS)
        m["normalTexture"] = {"index": glb.image(im, "png"), "scale": float(g["mat"].get("normalmapIntensity", 1.0))}
    J["materials"].append(m); g["material"] = len(J["materials"]) - 1

# skeleton nodes (bind pose = ANNY rest bone poses, rotated into glTF frame)
parents = list(soma.bone_parents)
Wg = np.einsum("ij,bjk->bik", Cm, SB)
first_bone = len(J["nodes"]) + 0
bone_node = {}
max_ortho_err = 0.0
for b, lab in enumerate(soma.bone_labels):
    p = parents[b]
    L = Wg[b] if p < 0 else np.linalg.inv(Wg[p]) @ Wg[b]
    Rm = L[:3, :3]
    max_ortho_err = max(max_ortho_err, float(np.abs(Rm @ Rm.T - np.eye(3)).max()))
    q = roma.rotmat_to_unitquat(torch.tensor(Rm)[None]).numpy()[0]   # roma: XYZW, same as glTF
    J["nodes"].append({"name": lab, "translation": L[:3, 3].tolist(), "rotation": (q / np.linalg.norm(q)).tolist()})
    bone_node[b] = len(J["nodes"]) - 1
for b in range(NB):
    ch = [bone_node[c] for c in range(NB) if parents[c] == b]
    if ch:
        J["nodes"][bone_node[b]]["children"] = ch
roots = [bone_node[b] for b in range(NB) if parents[b] < 0]
log("bone roots", [J["nodes"][r]["name"] for r in roots], "rest rotation ortho err", max_ortho_err)
ibm = np.stack([np.linalg.inv(Wg[b]).T for b in range(NB)]).astype(np.float32)  # column-major
J["skins"].append({"name": "soma_rig", "joints": [bone_node[b] for b in range(NB)], "skeleton": roots[0],
                   "inverseBindMatrices": glb.acc(ibm.reshape(NB, 16), "MAT4", 5126)})

mesh_stats = {}
mesh_stats["body_anny_soma"] = add_mesh("body_anny_soma", SV, sVT, SF[keepF], SFT[keepF], sw_dense, 0)
for g in garments:
    mesh_stats[g["name"]] = add_mesh(g["name"], g["V"], g["VT"], g["F"], g["FT"], g["dense"], g["material"])
mesh_nodes = [i for i, n in enumerate(J["nodes"]) if "mesh" in n]
J["nodes"].append({"name": "Woman", "children": roots + mesh_nodes})
J["scenes"][0]["nodes"] = [len(J["nodes"]) - 1]
glb.write(OUT)

height = float(to_gltf(SV)[:, 1].max())
STATS.update(dict(phenotype=PHENOTYPE, clothes=CLOTHES, assets=ASSETS, skin=SKIN, meshes=mesh_stats, bones=NB, height_m=height,
                  soma_hidden_verts=int(s_del.sum()), soma_faces_kept=int(keepF.sum()), soma_faces_total=int(SF.shape[0]),
                  garments={g["name"]: {"mean_dist_to_body_m": float(g["body_dist"].mean()), "max_dist_to_body_m": float(g["body_dist"].max()),
                                         "verts_inside_full_body_frac": g["inside_frac"],
                                         "verts_inside_visible_body_within_1cm_frac": g["inside_visible_frac"], "offset_scale_xyz": g["scale"].tolist()} for g in garments},
                  glb_bytes=os.path.getsize(OUT), rest_rotation_ortho_err=max_ortho_err))
json.dump(STATS, open(os.path.join(HERE, "build_stats.json"), "w"), indent=2)
log(json.dumps(STATS, indent=1))
