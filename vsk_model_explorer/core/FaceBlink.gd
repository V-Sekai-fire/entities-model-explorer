# Gives a VRM 1.0 file the anime eye closes of headfit.elf (RFD 2275's anime style) that it lacks:
# - without one-eye blinks: EyeClosedLeft and EyeClosedRight (procedural:anime_eye_close_plain_*)
#   on the face mesh, bound to blinkLeft and blinkRight, and to blink too when the avatar has no
#   blink of its own (an own both-eyes blink is kept);
# - without a happy expression: EyeClosedSmileLeft and EyeClosedSmileRight (the smile close, ^^,
#   procedural:anime_eye_close_smile_*), bound to happy with overrideBlink "block".
# The file is edited at the glTF level: the binary chunk only grows, and the JSON is written back
# whole (numbers at Godot's 15 significant digits).
#
# The face mesh is the one whose materials name both skin and an eye (FaceRoles); a mesh that is
# all eye (an iris on its own mesh), or has eye vertices on one side only, is never the face. A vertex whose strongest joint is the
# humanoid leftEye or rightEye (or a bone under it) is an iris whatever its material says (unless
# lash or brow): it turns with the eye, so the lids close over it. That finds the eyes of a face
# whose materials name no lash or iris (an avatar's own closes, as the answer key: the bones give
# 0.587 on one with only an "eye" material, and change nothing where the names are complete). VRM 1.0 faces +Z with the avatar's left on
# +X; headfit's frame is Z up, -Y forward, left +X: (x, y, z) -> (x, -z, y).
class_name FaceBlink
extends RefCounted

const FaceRoles := preload("res://vsk_model_explorer/core/FaceRoles.gd")
const ELF := "res://headfit.elf"
# kind -> [morph target, expression]: the plain closes are the one-eye blinks; the smile closes
# (^^, both lids meet) are the eyes of the happy expression.
const PLAIN := [
	["anime_eye_close_plain_left", "EyeClosedLeft", "blinkLeft"],
	["anime_eye_close_plain_right", "EyeClosedRight", "blinkRight"],
]
const SMILE := [
	["anime_eye_close_smile_left", "EyeClosedSmileLeft", "happy"],
	["anime_eye_close_smile_right", "EyeClosedSmileRight", "happy"],
]

# What the last add() did, for the log: {face, vertices, moved_left, moved_right} or {skipped}.
var report := {}
var _json: Dictionary
var _bin: PackedByteArray
var _names := {}  # the material names of names_from (_primitive_names)
var _keep_blink := false  # the avatar's own both-eyes blink stays; only the one-eye closes are added
var _kinds := []  # the rows of PLAIN and SMILE this file gets


# Adds the closes to the VRM 1.0 file at `path` in place. force = also when the file has its own
# blink (then the generated ones replace its blink expressions; tests only). Returns "" when the
# file was changed or had nothing to change (see report.skipped), else why it failed.
#
# names_from: the file the VRM was made from. skintokens.elf's VRM step writes no material names,
# so the names are read from that file's matching mesh (_source_names).
func add(path: String, force := false, names_from := "") -> String:
	report = {}
	_names = {}
	if names_from != "":
		var why0 := _read(names_from)
		if why0 != "":
			return why0
		_names = _primitive_names()
	var why := _read(path)
	if why != "":
		return why
	var vrm: Dictionary = _json.get("extensions", {}).get("VRMC_vrm", {})
	if vrm.is_empty():
		report.skipped = "not a VRM 1.0 file"
		return ""
	var preset: Dictionary = vrm.get("expressions", {}).get("preset", {})
	var has := func(n: String) -> bool:
		return not preset.get(n, {}).get("morphTargetBinds", []).is_empty()
	_keep_blink = has.call("blink") and not force
	_kinds = []
	if force or not (has.call("blinkLeft") and has.call("blinkRight")):
		_kinds.append_array(PLAIN)
	if force or not has.call("happy"):
		_kinds.append_array(SMILE)
	if _kinds.is_empty():
		report.skipped = "the avatar has its own blinks and happy expression"
		return ""
	var face := _face()
	if face.is_empty():
		report.skipped = "no mesh names both skin and an eye"
		return ""
	if not ClassDB.class_exists("Sandbox") or not ResourceLoader.exists(ELF):
		return "the eye close needs headfit.elf and the godot-sandbox library"
	var sb: Node = ClassDB.instantiate("Sandbox")
	sb.memory_max = 256
	sb.execution_timeout = 0
	sb.load_buffer(FileAccess.get_file_as_bytes(ELF))
	for fn in ["hf_mesh_create", "hf_mesh_set_roles", "hf_anime_shape", "hf_error", "hf_destroy"]:
		if not sb.has_function(fn):
			sb.free()
			return "headfit.elf did not load (no %s)" % fn
	why = _generate(sb, face)
	sb.free()
	if why != "":
		return why
	return _write(path)


func _read(path: String) -> String:
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 20 or b.decode_u32(0) != 0x46546C67:
		return "not a binary glTF: " + path.get_file()
	var jl := b.decode_u32(12)
	var parsed = JSON.parse_string(b.slice(20, 20 + jl).get_string_from_utf8())
	if not (parsed is Dictionary):
		return "cannot read the glTF JSON of " + path.get_file()
	_json = parsed
	_bin = PackedByteArray()
	var at := 20 + jl
	if at + 8 <= b.size() and b.decode_u32(at + 4) == 0x004E4942:
		_bin = b.slice(at + 8, at + 8 + b.decode_u32(at))
	return ""


func _write(path: String) -> String:
	while _bin.size() % 4:
		_bin.append(0)
	_json.buffers[0].byteLength = _bin.size()
	# Godot's JSON reads every number as a float and would write an index back as "3.0".
	var j := JSON.stringify(_integral(_json)).to_utf8_buffer()
	while j.size() % 4:
		j.append(0x20)
	var out := PackedByteArray()
	out.resize(12)
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(8, 12 + 8 + j.size() + 8 + _bin.size())
	var head := PackedByteArray()
	head.resize(8)
	head.encode_u32(0, j.size())
	head.encode_u32(4, 0x4E4F534A)
	out.append_array(head)
	out.append_array(j)
	head.encode_u32(0, _bin.size())
	head.encode_u32(4, 0x004E4942)
	out.append_array(head)
	out.append_array(_bin)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write " + path
	f.store_buffer(out)
	f.close()
	return ""


# The source's material names per primitive, by mesh: {"by_index": [...], "by_name": {...}}.
# skintokens.elf's VRM step keeps the meshes in order and their primitives, renamed
# <model>_<mesh name with '.' as '_'>, and splits shared vertex buffers per primitive.
func _primitive_names() -> Dictionary:
	var by_index := []
	var by_name := {}
	for mesh in _json.get("meshes", []):
		var names := []
		for prim in mesh.primitives:
			names.append(_material_name(prim))
		by_index.append(names)
		by_name[str(mesh.get("name", "")).replace(".", "_").to_lower()] = names
	return {"by_index": by_index, "by_name": by_name}


func _source_names(mi: int) -> Array:
	if _names.is_empty():
		return []
	var mesh: Dictionary = _json.meshes[mi]
	var n := str(mesh.get("name", "")).to_lower()
	for key: String in _names.by_name:
		if key != "" and (n == key or n.ends_with("_" + key)):
			if (_names.by_name[key] as Array).size() == mesh.primitives.size():
				return _names.by_name[key]
	if (
		(_names.by_index as Array).size() == _json.meshes.size()
		and (_names.by_index[mi] as Array).size() == mesh.primitives.size()
	):
		return _names.by_index[mi]
	return []


static func _integral(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if is_finite(v) and v == floorf(v) and absf(v) < 9.0e15 else v
		TYPE_ARRAY:
			var a := []
			for x in v:
				a.append(_integral(x))
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = _integral(v[k])
			return d
	return v


func _material_name(prim: Dictionary) -> String:
	if not prim.has("material"):
		return ""
	var n = _json.materials[int(prim.material)].get("name", "")
	return "" if n == null else str(n)


func _material_role(mi: int, k: int) -> int:
	var name := _material_name(_json.meshes[mi].primitives[k])
	var src := _source_names(mi)
	if name == "" and not src.is_empty():
		name = src[k]
	return FaceRoles.role_of(name)


# The face: {node, mesh, accessors: [POSITION accessor ids in vertex order], roles, xyz, tri}.
func _face() -> Dictionary:
	var best := {}
	for ni in _json.get("nodes", []).size():
		var node: Dictionary = _json.nodes[ni]
		if not node.has("mesh"):
			continue
		var to_model := _mesh_to_model(ni)
		var mesh: Dictionary = _json.meshes[int(node.mesh)]
		var accs := []
		var first := {}
		var ok := true
		for prim in mesh.primitives:
			if int(prim.get("mode", 4)) != 4 or not prim.has("indices"):
				ok = false
			var a := int(prim.attributes.POSITION)
			if not first.has(a):
				first[a] = 0
				for b in accs:
					first[a] += int(_json.accessors[b].count)
				accs.append(a)
		if not ok:
			continue
		var n := 0
		for a in accs:
			n += int(_json.accessors[a].count)
		var roles := PackedInt32Array()
		roles.resize(n)
		roles.fill(-1)
		var tri := PackedInt32Array()
		for pk in mesh.primitives.size():
			var prim: Dictionary = mesh.primitives[pk]
			var r := _material_role(int(node.mesh), pk)
			var base: int = first[int(prim.attributes.POSITION)]
			var idx := _ints(int(prim.indices))
			for i in idx:
				# A vertex two primitives share takes the non-skin role (the eye side of a seam).
				if roles[base + i] <= FaceRoles.SKIN:
					roles[base + i] = r
			for k in range(0, idx.size() - 2, 3):
				tri.append(base + idx[k])
				tri.append(base + idx[k + 1])
				tri.append(base + idx[k + 2])
		_eye_bone_roles(ni, mesh, first, roles)
		var xyz := PackedFloat32Array()
		for a in accs:
			var p := _vec3(a)
			if p.is_empty():
				ok = false
			for v in p:
				var w := to_model * v
				xyz.append_array([w.x, -w.z, w.y])
		# Eye vertices on both sides of the middle: a body mesh carrying one eye's material is not
		# the face.
		var eye := 0
		var skin := 0
		var left := 0
		var right := 0
		for i in roles.size():
			var r := roles[i]
			if r == FaceRoles.EYE or r == FaceRoles.LASH or r == FaceRoles.IRIS:
				eye += 1
				if i * 3 < xyz.size():
					left += 1 if xyz[i * 3] > 0.0 else 0
					right += 1 if xyz[i * 3] < 0.0 else 0
			skin += 1 if r == FaceRoles.SKIN else 0
		if eye == 0 or skin == 0 or left == 0 or right == 0:
			continue
		# The face holds the lids: the most skin vertices touching the eyes. Kimono's body mesh
		# has eyeballs behind the face but no lids (186 such vertices against the face's 792).
		var lids := _skin_near_eyes(roles, xyz)
		if lids == 0 or (not best.is_empty() and lids <= best.eye):
			continue
		for i in roles.size():
			roles[i] = maxi(roles[i], FaceRoles.SKIN)
		if ok:
			best = {
				"node": ni,
				"mesh": int(node.mesh),
				"accessors": accs,
				"roles": roles,
				"xyz": xyz,
				"tri": tri,
				"eye": lids,
				"back": to_model.basis.inverse(),
			}
	return best


# Skin vertices within a tenth of an eye's width (half the eyes' span in x) of an eye vertex.
static func _skin_near_eyes(roles: PackedInt32Array, xyz: PackedFloat32Array) -> int:
	var lo := INF
	var hi := -INF
	var eyes := []
	for i in roles.size():
		var r := roles[i]
		if (
			(r == FaceRoles.EYE or r == FaceRoles.LASH or r == FaceRoles.IRIS)
			and i * 3 + 2 < xyz.size()
		):
			eyes.append(i)
			lo = minf(lo, xyz[i * 3])
			hi = maxf(hi, xyz[i * 3])
	var reach := (hi - lo) * 0.5 * 0.1
	if eyes.is_empty() or reach <= 0.0:
		return 0
	var at := func(i: int) -> Vector3: return Vector3(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2])
	var grid := {}
	for i: int in eyes:
		var c := Vector3i((at.call(i) / reach).floor())
		if not grid.has(c):
			grid[c] = []
		grid[c].append(i)
	var n := 0
	for i in roles.size():
		if roles[i] != FaceRoles.SKIN or i * 3 + 2 >= xyz.size():
			continue
		var p: Vector3 = at.call(i)
		var c := Vector3i((p / reach).floor())
		var near := false
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					for j: int in grid.get(c + Vector3i(dx, dy, dz), []):
						if not near and p.distance_to(at.call(j)) < reach:
							near = true
		n += 1 if near else 0
	return n


# The skin joints of node `ni` that are the humanoid eyes or bones under them.
func _eye_joints(ni: int) -> Dictionary:
	var out := {}
	var node: Dictionary = _json.nodes[ni]
	if not node.has("skin"):
		return out
	var bones: Dictionary = _json.extensions.VRMC_vrm.get("humanoid", {}).get("humanBones", {})
	var todo := []
	for b in ["leftEye", "rightEye"]:
		if bones.has(b):
			todo.append(int(bones[b].node))
	var under := {}
	while not todo.is_empty():
		var n: int = todo.pop_back()
		under[n] = true
		for c in _json.nodes[n].get("children", []):
			todo.append(int(c))
	var joints: Array = _json.skins[int(node.skin)].joints
	for j in joints.size():
		if under.has(int(joints[j])):
			out[j] = true
	return out


# Marks as IRIS the skin or eye vertices whose strongest joint is an eye (see the header).
func _eye_bone_roles(ni: int, mesh: Dictionary, first: Dictionary, roles: PackedInt32Array) -> void:
	var eyes := _eye_joints(ni)
	if eyes.is_empty():
		return
	var done := {}
	for prim in mesh.primitives:
		var a := int(prim.attributes.POSITION)
		if (
			done.has(a)
			or not prim.attributes.has("JOINTS_0")
			or not prim.attributes.has("WEIGHTS_0")
		):
			continue
		done[a] = true
		var j := _vec4(int(prim.attributes.JOINTS_0))
		var w := _vec4(int(prim.attributes.WEIGHTS_0))
		var base: int = first[a]
		for i in mini(j.size(), w.size()) / 4:
			var k := 0
			for c in range(1, 4):
				if w[i * 4 + c] > w[i * 4 + k]:
					k = c
			var r := roles[base + i]
			if w[i * 4 + k] > 0.0 and eyes.has(int(j[i * 4 + k])):
				if r == FaceRoles.SKIN or r == FaceRoles.EYE:
					roles[base + i] = FaceRoles.IRIS


# A VEC4 accessor as floats (joints as their indices, normalized weights scaled to 0..1).
func _vec4(a: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var v := _view(a)
	if v.is_empty() or v[2].type != "VEC4":
		return out
	var ct := int(v[2].componentType)
	var size := 1 if ct == 5121 else (2 if ct == 5123 else 4)
	var stride: int = v[1] if v[1] > 0 else size * 4
	var norm: bool = v[2].get("normalized", false) and ct != 5126
	for i in int(v[2].count):
		for c in 4:
			var o: int = v[0] + i * stride + c * size
			var x: float = (
				_bin.decode_float(o)
				if ct == 5126
				else float(_bin[o] if ct == 5121 else _bin.decode_u16(o))
			)
			out.append(x / (255.0 if ct == 5121 else 65535.0) if norm else x)
	return out


# Mesh space to the model's space (+Z forward, +Y up, left +X): the node's world transform.
# skintokens.elf's VRM step writes every mesh in model space, so for its files this is the identity.
func _mesh_to_model(ni: int) -> Transform3D:
	return _world(ni)


func _world(ni: int) -> Transform3D:
	var parent := {}
	for i in _json.nodes.size():
		for c in _json.nodes[i].get("children", []):
			parent[int(c)] = i
	var t := Transform3D.IDENTITY
	var at := ni
	while true:
		t = _local(_json.nodes[at]) * t
		if not parent.has(at):
			break
		at = parent[at]
	return t


static func _local(n: Dictionary) -> Transform3D:
	if n.has("matrix"):
		var m: Array = n.matrix
		return Transform3D(
			Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])),
			Vector3(m[12], m[13], m[14])
		)
	var r: Array = n.get("rotation", [0, 0, 0, 1])
	var s: Array = n.get("scale", [1, 1, 1])
	var p: Array = n.get("translation", [0, 0, 0])
	var b := Basis(Quaternion(r[0], r[1], r[2], r[3])).scaled(Vector3(s[0], s[1], s[2]))
	return Transform3D(b, Vector3(p[0], p[1], p[2]))


func _generate(sb: Node, face: Dictionary) -> String:
	var mesh = sb.vmcall("hf_mesh_create", face.xyz, face.tri)
	if typeof(mesh) != TYPE_INT or mesh < 0:
		return "headfit.elf: " + str(sb.vmcall("hf_error"))
	if int(sb.vmcall("hf_mesh_set_roles", mesh, face.roles)) < 0:
		return "headfit.elf: " + str(sb.vmcall("hf_error"))
	var m: Dictionary = _json.meshes[face.mesh]
	var names: Array = m.get("extras", {}).get("targetNames", [])
	var ntargets: int = m.primitives[0].get("targets", []).size()
	while names.size() < ntargets:
		names.append("target%d" % names.size())
	var preset: Dictionary = _json.extensions.VRMC_vrm.get("expressions", {}).get("preset", {})
	var both := []
	var happy := []
	report = {"face": str(m.get("name", face.mesh)), "vertices": face.xyz.size() / 3}
	var added := 0
	for k in _kinds.size():
		var d: PackedFloat32Array = sb.vmcall("hf_anime_shape", mesh, _kinds[k][0])
		if d.size() != face.xyz.size():
			if _kinds[k][2] == "happy":
				# An older headfit.elf has no smile close: the blinks still go in.
				report.happy = "skipped: " + str(sb.vmcall("hf_error"))
				continue
			return "headfit.elf: " + str(sb.vmcall("hf_error"))
		# Back to glTF: (dx, dy, dz) fit -> (dx, dz, -dy).
		var moved := 0
		var at := 0
		var made := {}
		for a in face.accessors:
			var n := int(_json.accessors[a].count)
			var pts := PackedVector3Array()
			pts.resize(n)
			for i in n:
				var j := (at + i) * 3
				pts[i] = face.back * Vector3(d[j], d[j + 2], -d[j + 1])
				moved += 1 if pts[i] != Vector3.ZERO else 0
			made[a] = _add_vec3(pts)
			at += n
		for prim in m.primitives:
			if not prim.has("targets"):
				prim.targets = []
			prim.targets.append({"POSITION": made[int(prim.attributes.POSITION)]})
		names.append(_kinds[k][1])
		if m.has("weights"):
			m.weights.append(0.0)
		var bind := {"node": face.node, "index": ntargets + added, "weight": 1.0}
		added += 1
		if _kinds[k][2] == "happy":
			happy.append(bind)
		else:
			both.append(bind)
			preset[_kinds[k][2]] = _expression([bind])
		report["moved_" + _kinds[k][1]] = moved
	if not both.is_empty():
		if not _keep_blink:
			preset.blink = _expression(both)
		report.blink = "own" if _keep_blink else "generated"
	if not happy.is_empty():
		# The smile eyes stand in for the blink while happy shows: VRM 1.0's overrideBlink "block".
		var e := _expression(happy)
		e.overrideBlink = "block"
		preset.happy = e
		report.happy = "generated eyes"
	if not m.has("extras"):
		m.extras = {}
	m.extras.targetNames = names
	if not _json.extensions.VRMC_vrm.has("expressions"):
		_json.extensions.VRMC_vrm.expressions = {}
	_json.extensions.VRMC_vrm.expressions.preset = preset
	sb.vmcall("hf_destroy", mesh)
	return ""


static func _expression(binds: Array) -> Dictionary:
	return {
		"morphTargetBinds": binds,
		"isBinary": false,
		"overrideBlink": "none",
		"overrideLookAt": "none",
		"overrideMouth": "none",
	}


func _view(a: int) -> Array:
	var acc: Dictionary = _json.accessors[a]
	if acc.has("sparse") or not acc.has("bufferView"):
		return []
	var bv: Dictionary = _json.bufferViews[int(acc.bufferView)]
	return [
		int(bv.get("byteOffset", 0)) + int(acc.get("byteOffset", 0)),
		int(bv.get("byteStride", 0)),
		acc
	]


func _vec3(a: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var v := _view(a)
	if v.is_empty() or int(v[2].componentType) != 5126 or v[2].type != "VEC3":
		return out
	var stride: int = v[1] if v[1] > 0 else 12
	for i in int(v[2].count):
		var o: int = v[0] + i * stride
		out.append(
			Vector3(_bin.decode_float(o), _bin.decode_float(o + 4), _bin.decode_float(o + 8))
		)
	return out


func _ints(a: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var v := _view(a)
	if v.is_empty():
		return out
	var ct := int(v[2].componentType)
	var size := 1 if ct == 5121 else (2 if ct == 5123 else 4)
	var stride: int = v[1] if v[1] > 0 else size
	for i in int(v[2].count):
		var o: int = v[0] + i * stride
		out.append(
			_bin[o] if ct == 5121 else (_bin.decode_u16(o) if ct == 5123 else _bin.decode_u32(o))
		)
	return out


func _add_vec3(pts: PackedVector3Array) -> int:
	while _bin.size() % 4:
		_bin.append(0)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var b := PackedByteArray()
	b.resize(pts.size() * 12)
	for i in pts.size():
		lo = lo.min(pts[i])
		hi = hi.max(pts[i])
		b.encode_float(i * 12, pts[i].x)
		b.encode_float(i * 12 + 4, pts[i].y)
		b.encode_float(i * 12 + 8, pts[i].z)
	_json.bufferViews.append({"buffer": 0, "byteOffset": _bin.size(), "byteLength": b.size()})
	_bin.append_array(b)
	(
		_json
		. accessors
		. append(
			{
				"bufferView": _json.bufferViews.size() - 1,
				"componentType": 5126,
				"count": pts.size(),
				"type": "VEC3",
				"min": [lo.x, lo.y, lo.z],
				"max": [hi.x, hi.y, hi.z],
			}
		)
	)
	return _json.accessors.size() - 1
