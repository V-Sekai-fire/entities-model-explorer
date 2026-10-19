extends RefCounted
# Writes a rigged humanoid as a VRM 1.0 file. The humanoid roles come from the rig program's
# matcher (role -> skeleton bone name). The export renames those bones to Godot's humanoid names,
# turns the model to face +Z (left on +X), swaps every material to MToon and writes the file with
# the VRM add-on's glTF extensions. Materials are always MToon: many VRM players refuse PBR.
# MToon defaults come from a ColorChecker calibration against the PBR look (24 patches, mean
# dE2000 1.5 under neutral light, 2.3 under the viewer's sky in physical light units): shade =
# 0.2 x base, toony 0.2, shift 0, giEqualization 0.1. The MToon 1.0 defaults score 7.0 there.

const SHADE := 0.2
const TOONY := 0.2
const SHIFT := 0.0
const INDIRECT := 0.9  # = 1 - giEqualizationFactor
const SHADER_DIR := "res://addons/Godot-MToon-Shader/"
const LICENSE_URL := "https://vrm.dev/licenses/1.0/"
const VRMTopLevel := preload("res://addons/vrm/vrm_toplevel.gd")
const VRMMeta := preload("res://addons/vrm/vrm_meta.gd")
const EXTENSIONS := [
	preload("res://addons/vrm/1.0/VRMC_vrm.gd"),
	preload("res://addons/vrm/1.0/VRMC_node_constraint.gd"),
	preload("res://addons/vrm/1.0/VRMC_springBone.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_hdr_emissiveMultiplier.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_mtoon.gd"),
]
const NAMED_SKIN_BINDS := 16  # EditorSceneFormatImporter.IMPORT_USE_NAMED_SKIN_BINDS
const ROLE_TO_HUMAN := {
	"hips": "Hips",
	"spine1": "Spine",
	"spine2": "Chest",
	"chest": "UpperChest",
	"neck": "Neck",
	"head": "Head",
	"left_shoulder": "LeftShoulder",
	"left_upper_arm": "LeftUpperArm",
	"left_forearm": "LeftLowerArm",
	"left_hand": "LeftHand",
	"right_shoulder": "RightShoulder",
	"right_upper_arm": "RightUpperArm",
	"right_forearm": "RightLowerArm",
	"right_hand": "RightHand",
	"left_upper_leg": "LeftUpperLeg",
	"left_shin": "LeftLowerLeg",
	"left_foot": "LeftFoot",
	"left_toe": "LeftToes",
	"right_upper_leg": "RightUpperLeg",
	"right_shin": "RightLowerLeg",
	"right_foot": "RightFoot",
	"right_toe": "RightToes",
}
const REQUIRED := [
	"hips",
	"spine1",
	"head",
	"left_upper_arm",
	"left_forearm",
	"left_hand",
	"right_upper_arm",
	"right_forearm",
	"right_hand",
	"left_upper_leg",
	"left_shin",
	"left_foot",
	"right_upper_leg",
	"right_shin",
	"right_foot",
]

var report := {}  # what the export decided, for logs and tests


# Returns "" on success, else why the model does not fit a VRM.
func export_vrm(glb_path: String, roles: Dictionary, out_path: String) -> String:
	for r in REQUIRED:
		if not roles.has(r):
			return "no %s bone" % r
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb_path, state) != OK:
		return "cannot read " + glb_path
	var scene: Node = doc.generate_scene(state)
	var why := _build(scene, roles, glb_path.get_file().get_basename().trim_suffix(".rigged"))
	if why == "":
		why = _write(scene, out_path)
	scene.free()
	return why


func _build(scene: Node, roles: Dictionary, title: String) -> String:
	var skel: Skeleton3D
	for s in scene.find_children("*", "Skeleton3D", true, false):
		if s.find_bone(roles.hips) >= 0:
			skel = s
	if skel == null:
		return "no skeleton holds the hips bone"
	roles = roles.duplicate()
	if not roles.has("spine2") and roles.has("chest"):
		roles.spine2 = roles.chest  # VRM needs chest before upperChest
		roles.erase("chest")
	var to_scene := _to_root(skel, scene)
	var p := func(role: String) -> Vector3:
		return to_scene * skel.get_bone_global_rest(skel.find_bone(roles[role])).origin
	if p.call("head").y <= p.call("hips").y:
		return "the model is not upright (head below hips)"
	# Facing: left-right from the upper legs; forward = left x up. The toes must agree, otherwise
	# the matcher's sides are swapped.
	var left: Vector3 = p.call("left_upper_leg") - p.call("right_upper_leg")
	left.y = 0
	var forward := left.cross(Vector3.UP).normalized()
	if roles.has("left_toe") and roles.has("right_toe"):
		var toes: Vector3 = (
			(p.call("left_toe") - p.call("left_foot"))
			+ (p.call("right_toe") - p.call("right_foot"))
		)
		toes.y = 0
		report.toe_agreement = toes.normalized().dot(forward)
		if report.toe_agreement < 0:
			roles = _swap_sides(roles)
			forward = -forward
	var yaw := atan2(forward.x, forward.z)
	report.turned_degrees = rad_to_deg(-yaw)
	_turn(scene, skel, Transform3D(Basis(Vector3.UP, -yaw), Vector3.ZERO), to_scene)
	report.arm_drop_before = _t_pose(scene, skel, roles, to_scene)
	# The VRM carries no clips: its rest pose is the pose.
	for ap in scene.find_children("*", "AnimationPlayer", true, false):
		ap.get_parent().remove_child(ap)
		ap.free()
	_rename_bones(scene, skel, roles)
	skel.name = "GeneralSkeleton"
	report.mtoon_materials = _to_mtoon(scene)
	report.roles = roles
	# Wrap in the VRM top level.
	var root := Node3D.new()
	root.name = title
	root.set_script(VRMTopLevel)
	var meta: VRMMeta = VRMMeta.new()
	meta.spec_version = "1.0"
	meta.title = title
	meta.version = "1.0"
	meta.authors = PackedStringArray(["Unknown"])
	meta.license_url = LICENSE_URL
	meta.allowed_user_name = "OnlyAuthor"
	meta.violent_usage = "Disallow"
	meta.sexual_usage = "Disallow"
	meta.commercial_usage_type = "PersonalNonProfit"
	meta.political_religious_usage = "Disallow"
	meta.antisocial_hate_usage = "Disallow"
	meta.credit_notation = "Required"
	meta.allow_redistribution = "Disallow"
	meta.modification = "Prohibited"
	root.vrm_meta = meta
	# Godot's multi-root export drops the joints of a Skeleton3D that is itself a scene root, so
	# the skeleton hangs under a plain "Armature" node.
	var armature := Node3D.new()
	armature.name = "Armature"
	root.add_child(armature)
	for c in scene.get_children():
		_own(c, null)
		c.owner = null
		scene.remove_child(c)
		armature.add_child(c)
	_own(root, root)
	skel.unique_name_in_owner = true
	scene.add_child(root)
	return ""


func _write(scene: Node, out_path: String) -> String:
	var root: Node = scene.get_child(0)
	scene.remove_child(root)
	var exts := []
	for e in EXTENSIONS:
		exts.append(e.new())
		GLTFDocument.register_gltf_document_extension(exts[-1])
	var doc := GLTFDocument.new()
	doc.root_node_mode = GLTFDocument.ROOT_NODE_MODE_MULTI_ROOT
	var state := GLTFState.new()
	state.set_meta("vrm", "1.0")
	state.set_meta("anim_player", null)  # VRMC_vrm reads it even when there is no clip
	var err := doc.append_from_scene(root, state, NAMED_SKIN_BINDS)
	# GLTFDocument picks binary output by the .glb extension only.
	var tmp := out_path + ".tmp.glb"
	if err == OK:
		err = doc.write_to_filesystem(state, tmp)
	if err == OK:
		DirAccess.remove_absolute(out_path)
		err = DirAccess.rename_absolute(tmp, out_path)
	for e in exts:
		GLTFDocument.unregister_gltf_document_extension(e)
	root.free()
	return "" if err == OK else "VRM write failed (%s)" % error_string(err)


static func _to_root(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != root and n is Node3D:
		t = n.transform * t
		n = n.get_parent()
	return t


# VRM's rest pose is a T-pose: arms straight out along +-X. An arm hanging more than
# T_POSE_TOLERANCE degrees below that is raised by turning the upper arm and then the forearm,
# and the meshes are re-bound in the new rest pose (_bake_rest). Returns the drops it found.
const T_POSE_TOLERANCE := 5.0


static func _t_pose(
	scene: Node, skel: Skeleton3D, roles: Dictionary, to_scene: Transform3D
) -> Array:
	var drops := []
	var new_rest := {}
	var to_skel := to_scene.basis.inverse()
	for side in ["left", "right"]:
		var out_dir: Vector3 = (
			(to_skel * (Vector3.RIGHT if side == "left" else Vector3.LEFT)).normalized()
		)
		var chain := [roles[side + "_upper_arm"], roles[side + "_forearm"], roles[side + "_hand"]]
		var idx := chain.map(func(n): return skel.find_bone(n))
		var d: Vector3 = (
			to_scene.basis
			* (
				_global_rest(skel, idx[1], new_rest).origin
				- _global_rest(skel, idx[0], new_rest).origin
			)
		)
		var drop := rad_to_deg(atan2(-d.y, Vector2(d.x, d.z).length()))
		drops.append(snappedf(drop, 0.1))
		if absf(drop) <= T_POSE_TOLERANCE:
			continue
		for k in 2:  # upper arm, then forearm, each pointed along out_dir
			var g := _global_rest(skel, idx[k], new_rest)
			var dir := (_global_rest(skel, idx[k + 1], new_rest).origin - g.origin).normalized()
			var q := Quaternion(dir, out_dir)
			var parent := skel.get_bone_parent(idx[k])
			var pg := _global_rest(skel, parent, new_rest) if parent >= 0 else Transform3D.IDENTITY
			var ng := Transform3D(Basis(q) * g.basis, g.origin)
			new_rest[idx[k]] = pg.affine_inverse() * ng
	if not new_rest.is_empty():
		_bake_rest(scene, skel, new_rest)
	return drops


static func _global_rest(skel: Skeleton3D, bone: int, override: Dictionary) -> Transform3D:
	var t := Transform3D.IDENTITY
	while bone >= 0:
		t = (override[bone] if override.has(bone) else skel.get_bone_rest(bone)) * t
		bone = skel.get_bone_parent(bone)
	return t


# Re-binds every skinned mesh in a new rest pose. Per bone, D = (G B)^-1 * G' B moves a vertex
# from the old rest to the new one; vertices, normals, tangents and blend-shape deltas are blended
# by their skin weights, and binds become B' = G'^-1 G B so G' B' = G B (the mesh-to-skeleton map).
static func _bake_rest(scene: Node, skel: Skeleton3D, new_rest: Dictionary) -> void:
	var old_g := []
	var new_g := []
	for b in skel.get_bone_count():
		old_g.append(_global_rest(skel, b, {}))
		new_g.append(_global_rest(skel, b, new_rest))
	var done := {}
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		var skin: Skin = mi.skin
		if skin == null or not (mi.mesh is ArrayMesh) or done.has(mi.mesh):
			continue
		var d := []  # per bind index
		var new_binds := []
		for i in skin.get_bind_count():
			var b := skin.get_bind_bone(i)
			if skin.get_bind_name(i) != &"":
				b = skel.find_bone(skin.get_bind_name(i))
			var bind := skin.get_bind_pose(i)
			if b < 0:
				d.append(Transform3D.IDENTITY)
				new_binds.append(bind)
				continue
			d.append((old_g[b] * bind).affine_inverse() * new_g[b] * bind)
			new_binds.append(new_g[b].affine_inverse() * old_g[b] * bind)
		var src: ArrayMesh = mi.mesh
		var dst := ArrayMesh.new()
		dst.resource_name = src.resource_name
		dst.blend_shape_mode = src.blend_shape_mode
		for i in src.get_blend_shape_count():
			dst.add_blend_shape(src.get_blend_shape_name(i))
		var relative := src.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_RELATIVE
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			var per_vertex := _blend(arrays, d, src.surface_get_format(s))
			var shapes := []
			for shape in src.surface_get_blend_shape_arrays(s):
				shapes.append(_apply_per_vertex(shape, per_vertex, relative))
			arrays = _apply_per_vertex(arrays, per_vertex, false)
			var flags := src.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
			dst.add_surface_from_arrays(
				src.surface_get_primitive_type(s), arrays, shapes, {}, flags
			)
			dst.surface_set_material(s, src.surface_get_material(s))
			dst.surface_set_name(s, src.surface_get_name(s))
		done[src] = dst
		for i in skin.get_bind_count():
			skin.set_bind_pose(i, new_binds[i])
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		if done.has(mi.mesh):
			mi.mesh = done[mi.mesh]
	for b in new_rest:
		skel.set_bone_rest(b, new_rest[b])
		skel.set_bone_pose(b, new_rest[b])


# Per-vertex blended transform from the skin weights.
static func _blend(arrays: Array, d: Array, format: int) -> Array:
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var n: int = arrays[Mesh.ARRAY_VERTEX].size()
	var k := 8 if format & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 4
	var out := []
	out.resize(n)
	for v in n:
		var basis := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		var origin := Vector3.ZERO
		for j in k:
			var w := weights[v * k + j]
			if w == 0.0:
				continue
			var t: Transform3D = d[bones[v * k + j]]
			basis.x += t.basis.x * w
			basis.y += t.basis.y * w
			basis.z += t.basis.z * w
			origin += t.origin * w
		out[v] = Transform3D(basis, origin)
	return out


static func _apply_per_vertex(arrays: Array, per_vertex: Array, deltas: bool) -> Array:
	if arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		var p: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in p.size():
			var t: Transform3D = per_vertex[i]
			p[i] = t.basis * p[i] if deltas else t * p[i]
		arrays[Mesh.ARRAY_VERTEX] = p
	if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		var nr: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in nr.size():
			var t: Transform3D = per_vertex[i]
			nr[i] = t.basis.inverse().transposed() * nr[i]
			if not deltas:
				nr[i] = nr[i].normalized()
		arrays[Mesh.ARRAY_NORMAL] = nr
	if arrays[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
		var tg: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(0, tg.size(), 4):
			var t: Transform3D = per_vertex[i / 4]
			var r := t.basis * Vector3(tg[i], tg[i + 1], tg[i + 2])
			if not deltas:
				r = r.normalized()
			tg[i] = r.x
			tg[i + 1] = r.y
			tg[i + 2] = r.z
		arrays[Mesh.ARRAY_TANGENT] = tg
	return arrays


# Turns the model about the vertical axis. In skeleton space (turn t): root bone rests become
# t * rest, so every bone's global rest is t * G; skinned vertices become t * v and bind poses
# B * t^-1, so the skinned result is t * G * B * v and the stored mesh still matches its bind pose
# (VRM tools that read the bind pose see the turned model too). Unskinned nodes turn as nodes.
static func _turn(scene: Node, skel: Skeleton3D, turn: Transform3D, to_scene: Transform3D) -> void:
	if turn.basis.is_equal_approx(Basis.IDENTITY):
		return
	var t := to_scene.affine_inverse() * turn * to_scene
	for b in skel.get_parentless_bones():
		skel.set_bone_rest(b, t * skel.get_bone_rest(b))
		skel.set_bone_pose(b, skel.get_bone_rest(b))
	var skins := {}
	var meshes := {}
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		if mi.skin != null and mi.mesh is ArrayMesh:
			skins[mi.skin] = true
			if not meshes.has(mi.mesh):
				meshes[mi.mesh] = _transformed_mesh(mi.mesh, t)
			mi.mesh = meshes[mi.mesh]
		elif not skel.is_ancestor_of(mi):
			mi.transform = turn * mi.transform
	for skin: Skin in skins:
		for i in skin.get_bind_count():
			skin.set_bind_pose(i, skin.get_bind_pose(i) * t.affine_inverse())


static func _transformed_mesh(src: ArrayMesh, t: Transform3D) -> ArrayMesh:
	var dst := ArrayMesh.new()
	dst.resource_name = src.resource_name
	dst.blend_shape_mode = src.blend_shape_mode
	for i in src.get_blend_shape_count():
		dst.add_blend_shape(src.get_blend_shape_name(i))
	var relative := src.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_RELATIVE
	for s in src.get_surface_count():
		var arrays := _transform_arrays(src.surface_get_arrays(s), t, false)
		var shapes: Array = []
		for shape in src.surface_get_blend_shape_arrays(s):
			shapes.append(_transform_arrays(shape, t, relative))
		var flags := src.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		dst.add_surface_from_arrays(src.surface_get_primitive_type(s), arrays, shapes, {}, flags)
		dst.surface_set_material(s, src.surface_get_material(s))
		dst.surface_set_name(s, src.surface_get_name(s))
	return dst


static func _transform_arrays(arrays: Array, t: Transform3D, deltas: bool) -> Array:
	var basis := t.basis
	if arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] = basis * v[i] if deltas else t * v[i]
		arrays[Mesh.ARRAY_VERTEX] = v
	if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in n.size():
			n[i] = basis * n[i]
		arrays[Mesh.ARRAY_NORMAL] = n
	if arrays[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
		var tg: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(0, tg.size(), 4):
			var r := basis * Vector3(tg[i], tg[i + 1], tg[i + 2])
			tg[i] = r.x
			tg[i + 1] = r.y
			tg[i + 2] = r.z
		arrays[Mesh.ARRAY_TANGENT] = tg
	return arrays


static func _swap_sides(roles: Dictionary) -> Dictionary:
	var out := {}
	for r in roles:
		var s: String = r
		if s.begins_with("left_"):
			s = "right_" + s.substr(5)
		elif s.begins_with("right_"):
			s = "left_" + s.substr(6)
		out[s] = roles[r]
	return out


static func _rename_bones(scene: Node, skel: Skeleton3D, roles: Dictionary) -> void:
	var rename := {}
	for r in roles:
		rename[roles[r]] = ROLE_TO_HUMAN[r]
	var taken := {}
	for v in rename.values():
		taken[v] = true
	for i in skel.get_bone_count():  # a source bone already called "Head" etc. moves aside
		var n := skel.get_bone_name(i)
		if taken.has(n) and not rename.has(n):
			rename[n] = n + "_source"
	var old_names := {}
	for i in skel.get_bone_count():
		old_names[i] = skel.get_bone_name(i)
	for i in skel.get_bone_count():
		if rename.has(old_names[i]):
			skel.set_bone_name(i, "__vrm_tmp_%d" % i)
	for i in skel.get_bone_count():
		if rename.has(old_names[i]):
			skel.set_bone_name(i, rename[old_names[i]])
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		var skin: Skin = mi.skin
		if skin == null:
			continue
		for b in skin.get_bind_count():
			if rename.has(String(skin.get_bind_name(b))):
				skin.set_bind_name(b, rename[String(skin.get_bind_name(b))])


static func _to_mtoon(scene: Node) -> int:
	var made := {}
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(s)
			if src == null:
				src = mi.mesh.surface_get_material(s)
			if not made.has(src):
				made[src] = mtoon_from(src as BaseMaterial3D)
			mi.set_surface_override_material(s, made[src])
	return made.size()


static func mtoon_from(src: BaseMaterial3D) -> ShaderMaterial:
	var col := Color.WHITE
	var tex: Texture2D
	var variant := "mtoon"
	var m := ShaderMaterial.new()
	if src != null:
		col = src.albedo_color
		tex = src.albedo_texture
		if src.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			variant = "mtoon_cutout"
			m.set_shader_parameter("_AlphaCutoutEnable", 1.0)
			m.set_shader_parameter("_Cutoff", src.alpha_scissor_threshold)
		elif src.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			variant = "mtoon_trans"
		if src.cull_mode == BaseMaterial3D.CULL_DISABLED:
			variant += "_cull_off"
		if src.normal_enabled and src.normal_texture:
			m.set_shader_parameter("_BumpMap", src.normal_texture)
			m.set_shader_parameter("_BumpScale", src.normal_scale)
		if src.emission_enabled:
			m.set_shader_parameter("_EmissionColor", src.emission)
			m.set_shader_parameter("_EmissionMultiplier", src.emission_energy_multiplier)
			if src.emission_texture:
				m.set_shader_parameter("_EmissionMap", src.emission_texture)
		m.resource_name = src.resource_name
	m.shader = load(SHADER_DIR + variant + ".gdshader")
	# The VRM add-on reads every uniform back, so store the shader defaults explicitly first.
	var defaults := uniform_defaults()
	for u in defaults:
		if m.get_shader_parameter(u) == null:
			m.set_shader_parameter(u, defaults[u])
	m.set_shader_parameter("_Color", col)
	m.set_shader_parameter("_ShadeColor", Color(col.r * SHADE, col.g * SHADE, col.b * SHADE, 1.0))
	if tex:
		m.set_shader_parameter("_MainTex", tex)
		m.set_shader_parameter("_ShadeTexture", tex)
	m.set_shader_parameter("_ShadeToony", TOONY)
	m.set_shader_parameter("_ShadeShift", SHIFT)
	m.set_shader_parameter("_IndirectLightIntensity", INDIRECT)
	m.set_shader_parameter("_OutlineWidthMode", 0.0)
	return m


# Float and vec4 uniform defaults, read from the MToon shader source. RenderingServer cannot give
# them on a headless (dummy) renderer, and the VRM add-on fails on any unset uniform.
static func uniform_defaults() -> Dictionary:
	var out := {}
	var inc: ShaderInclude = load(SHADER_DIR + "mtoon_common.gdshaderinc")
	var re := RegEx.create_from_string(
		"uniform\\s+(float|vec4)\\s+(\\w+)[^=;]*=\\s*(?:vec4\\s*\\(([^)]*)\\)|([-0-9.]+))\\s*;"
	)
	for r in re.search_all(inc.code):
		if r.get_string(1) == "float":
			out[r.get_string(2)] = float(r.get_string(4))
		else:
			var v := r.get_string(3).split(",")
			out[r.get_string(2)] = Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
	return out


static func _own(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_own(c, owner)
