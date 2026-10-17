extends RefCounted
# Exploded view where no two pieces intersect, cut at the character's joints.
#
# Pieces: a skinned model comes apart where its skeleton branches into a big part, like an action
# figure. Every vertex belongs to the bone with the largest weight; a bone's "mass" is the number
# of vertices it holds. A bone starts a new part when its subtree holds at least MIN_SHARE of the
# skin and its parent has at least two such subtrees (hips -> legs and spine, chest -> arms and
# neck). Fingers, hair strands and skirt bones are below the share, so they stay with the hand,
# head or hips. No bone names are read, so VRM, Blender and Rigify rigs cut the same way. A
# part keeps every mesh and material skinned to it, so clothes stay on the body part they cover.
# Unskinned meshes go with the part of their BoneAttachment3D, or are a part of their own.
# A model with no skeleton and one surface falls back to a world grid (each triangle to the cell
# of its centroid). Copies are static, taken at the current pose.
#
# Directions: a part moves along its main chain from the joint where it was cut (an arm from
# shoulder to elbow, a leg from hip to knee, the head from neck to head), tilted half a step away
# from the body's centre line so left and right limbs spread apart; a part with no cut bone moves
# out from the model centre.
#
# Layout: piece i has a world-space box (centre c_i, half extents h_i) and a direction v_i. Parts
# are placed root first (fewest cuts above them), then nearest the centre; each moves along v_i
# by the smallest amount at which its box is at least `gap` away, on some axis, from every box
# placed before it. lean/Explode.lean defines that placement over exact rationals and proves
# (layout_sound, separated_disjoint) that no two boxes of a layout share a point, for any pieces,
# directions and order, so no two parts intersect. `lake exe explode_check` re-checks a layout
# printed by `print_layout()` in exact arithmetic.
#
# The guarantee is for the resting layout; during the short move-out animation pieces may pass
# through each other.

const WIRE_GROUP := "vsk_web_wire"
const GAP := 0.03  # minimum distance between boxes, as a share of the model radius
const MOVE_TIME := 0.35
const MIN_SHARE := 0.04  # a branch with at least this share of the skin becomes its own part
# Placement works with a gap slightly above GAP: candidates aim at AIM x gap, a spot counts as
# free at KEEP x gap; float32 rounding (about 1e-7 of the model size) stays far below the margin.
const AIM := 1.002
const KEEP := 1.001

var root: Node3D  # holds the piece copies while exploded
var hidden: Array = []  # nodes this script hid, restored by implode()
var centres: Array = []  # world box centres (Vector3)
var halves: Array = []  # world box half extents (Vector3)
var dirs: Array = []  # directions (Vector3)
var pieces: Array = []  # Node3D per part, holding its MeshInstance3D copies
var moves: Array = []  # how far each piece moves along its direction (float)
var gap := 0.0

# Per part while building: key -> index into the arrays below.
var part_of := {}
var part_axis: Array = []  # world direction of the part's main chain (Vector3), or null
var part_joint: Array = []  # world position of the cut joint (Vector3), or null
var part_depth: Array = []  # cuts above the part (int)
var part_box: Array = []  # world AABB


# Builds the pieces and moves them out. `models` are the loaded model roots; `parent` receives the
# piece root (it must not be inside a model, so the model's own animation does not move pieces).
func explode(models: Array, parent: Node, animate := true) -> void:
	implode()
	root = Node3D.new()
	root.name = "ExplodedPieces"
	parent.add_child(root)
	var mis: Array = []
	for model in models:
		for m in (model as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.is_in_group(WIRE_GROUP):
				if mi.visible:
					mi.visible = false
					hidden.append(mi)
				continue
			if mi.mesh == null or not _ancestors_visible(mi, model):
				continue
			mis.append(mi)
	if mis.is_empty():
		return
	var segs := _skeleton_segments(mis)
	for mi in mis:
		_split_mesh(mi, segs)
	if pieces.size() < 2:
		_grid_fallback(mis)
	for mi in mis:
		if (mi as MeshInstance3D).visible:
			(mi as MeshInstance3D).visible = false
			hidden.append(mi)
	if pieces.is_empty():
		return
	for i in pieces.size():
		var box: AABB = part_box[i]
		centres.append(box.get_center())
		halves.append(box.size * 0.5)
	_layout()
	for i in pieces.size():
		var p: Node3D = pieces[i]
		var target: Vector3 = p.global_position + (dirs[i] as Vector3) * float(moves[i])
		if animate:
			(
				p
				. create_tween()
				. tween_property(p, "global_position", target, MOVE_TIME)
				. set_trans(Tween.TRANS_CUBIC)
				. set_ease(Tween.EASE_OUT)
			)
		else:
			p.global_position = target


func implode() -> void:
	for n in hidden:
		if is_instance_valid(n):
			(n as Node3D).visible = true
	hidden.clear()
	if root != null and is_instance_valid(root):
		root.queue_free()
	root = null
	centres.clear()
	halves.clear()
	dirs.clear()
	pieces.clear()
	moves.clear()
	part_of.clear()
	part_axis.clear()
	part_joint.clear()
	part_depth.clear()
	part_box.clear()


func is_exploded() -> bool:
	return root != null


func _ancestors_visible(n: Node, stop: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != stop.get_parent():
		if p is Node3D and not (p as Node3D).visible:
			return false
		p = p.get_parent()
	return true


# --- Cutting the skeleton -------------------------------------------------------------------


func _skeleton_of(mi: MeshInstance3D) -> Skeleton3D:
	if mi.skin == null:
		return null
	return mi.get_node_or_null(mi.skeleton) as Skeleton3D


# Skeleton bone for each skin bind of `mi`.
func _bind_bones(mi: MeshInstance3D, sk: Skeleton3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	for b in mi.skin.get_bind_count():
		var bone := mi.skin.get_bind_bone(b)
		if bone < 0:
			bone = sk.find_bone(mi.skin.get_bind_name(b))
		out.append(bone)
	return out


# Per vertex of one surface, the skeleton bone with the largest weight (-1 if none).
func _dominant_bones(arrays: Array, binds: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null:
		return out
	var nv: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var bones_b := _blocks(arrays[Mesh.ARRAY_BONES])
	var wts_b := _blocks(arrays[Mesh.ARRAY_WEIGHTS])
	var nb: int = (arrays[Mesh.ARRAY_BONES] as PackedInt32Array).size()
	if nv == 0 or nb % nv != 0:
		return out
	var stride: int = nb / nv
	for v in nv:
		var best := -1
		var best_w := -1.0
		for k in stride:
			var i: int = v * stride + k
			var w: float = (wts_b[i / BLOCK] as PackedFloat32Array)[i % BLOCK]
			if w > best_w:
				best_w = w
				best = (bones_b[i / BLOCK] as PackedInt32Array)[i % BLOCK]
		var bone := -1
		if best >= 0 and best < binds.size():
			bone = binds[best]
		out.append(bone)
	return out


# Bones parent first.
func _bone_order(sk: Skeleton3D) -> PackedInt32Array:
	var order := PackedInt32Array(sk.get_parentless_bones())
	var i := 0
	while i < order.size():
		order.append_array(sk.get_bone_children(order[i]))
		i += 1
	return order


# For every skeleton used by `mis`: {skeleton: [segment, cut depth, subtree skin] per bone]. A bone's
# segment is the nearest bone at or above it that starts a part.
func _skeleton_segments(mis: Array) -> Dictionary:
	var mass := {}  # Skeleton3D -> PackedInt32Array (vertices held per bone)
	for mi in mis:
		var sk := _skeleton_of(mi)
		if sk == null:
			continue
		if not mass.has(sk):
			var z := PackedInt32Array()
			z.resize(sk.get_bone_count())
			mass[sk] = z
		var m: PackedInt32Array = mass[sk]
		var binds := _bind_bones(mi, sk)
		for s in (mi as MeshInstance3D).mesh.get_surface_count():
			var dom := _dominant_bones((mi as MeshInstance3D).mesh.surface_get_arrays(s), binds)
			for blk in _blocks(dom):
				for bone in blk as PackedInt32Array:
					if bone >= 0 and bone < m.size():
						m[bone] += 1
		mass[sk] = m
	var out := {}
	for sk in mass:
		var skel := sk as Skeleton3D
		var m: PackedInt32Array = mass[sk]
		var order := _bone_order(skel)
		var sub := m.duplicate()
		var total := 0
		for b in m:
			total += b
		for j in range(order.size() - 1, -1, -1):
			var b: int = order[j]
			var p := skel.get_bone_parent(b)
			if p >= 0:
				sub[p] += sub[b]
		var thr := maxf(1.0, MIN_SHARE * float(total))
		var seg := PackedInt32Array()
		seg.resize(skel.get_bone_count())
		var depth := PackedInt32Array()
		depth.resize(skel.get_bone_count())
		for b in order:
			var p := skel.get_bone_parent(b)
			var cut := p < 0
			if not cut and float(sub[b]) >= thr:
				var big := 0
				for c in skel.get_bone_children(p):
					if float(sub[c]) >= thr:
						big += 1
				cut = big >= 2
			if p < 0:
				seg[b] = b
				depth[b] = 0
			elif cut:
				seg[b] = b
				depth[b] = depth[p] + 1
			else:
				seg[b] = seg[p]
				depth[b] = depth[p]
		out[sk] = [seg, depth, sub]
	return out


# The part for a key, made on first use. `cut` is [axis, joint] of the cut, or [null, null].
func _part(key: String, depth: int, cut: Array) -> int:
	if part_of.has(key):
		return part_of[key]
	var holder := Node3D.new()
	holder.name = "Part%d" % pieces.size()
	root.add_child(holder)
	part_of[key] = pieces.size()
	pieces.append(holder)
	part_axis.append(cut[0])
	part_joint.append(cut[1])
	part_depth.append(depth)
	part_box.append(null)
	return part_of[key]


func _bone_world(sk: Skeleton3D, bone: int) -> Vector3:
	return sk.global_transform * sk.get_bone_global_pose(bone).origin


# The part an unskinned mesh joins: its BoneAttachment3D's part, else its own.
func _static_key(mi: MeshInstance3D, segs: Dictionary) -> Array:
	var n := mi.get_parent()
	while n != null:
		if n is BoneAttachment3D:
			var sk := n.get_parent() as Skeleton3D
			var bone: int = (n as BoneAttachment3D).bone_idx
			if sk != null and segs.has(sk) and bone >= 0:
				var cut: int = (segs[sk][0] as PackedInt32Array)[bone]
				var d: int = (segs[sk][1] as PackedInt32Array)[bone]
				return ["%d:%d" % [sk.get_instance_id(), cut], d, _cut_axis(sk, cut, segs[sk])]
			break
		n = n.get_parent()
	return ["mesh:%d" % mi.get_instance_id(), 0, [null, null]]


# [axis, joint] of a part cut at bone `cut`: joint is the cut bone's world position; axis runs from
# there down the part's main chain (each step to the child, in the same part, that holds at least
# half the part's skin): shoulder to elbow, hip to knee, neck to head. [null, null] for a root.
func _cut_axis(sk: Skeleton3D, cut: int, info: Array) -> Array:
	if sk.get_bone_parent(cut) < 0:
		return [null, null]
	var seg: PackedInt32Array = info[0]
	var sub: PackedInt32Array = info[2]
	var end := cut
	var half := 0.5 * float(sub[cut])
	while true:
		var next := -1
		for c in sk.get_bone_children(end):
			if seg[c] == cut and float(sub[c]) >= half and (next < 0 or sub[c] > sub[next]):
				next = c
		if next < 0:
			break
		end = next
	var joint := _bone_world(sk, cut)
	var a := _bone_world(sk, end) - joint
	if a.length() <= 1e-9:
		a = joint - _bone_world(sk, sk.get_bone_parent(cut))
	if a.length() <= 1e-9:
		return [null, joint]
	return [a, joint]


# Static copies of `mi`'s surfaces at the current pose, each split into the parts its triangles
# belong to (skinned meshes through bake_mesh_from_current_skeleton_pose(), blend-shaped ones
# through bake_mesh_from_current_blend_shape_mix()).
func _split_mesh(mi: MeshInstance3D, segs: Dictionary) -> void:
	var src: Mesh = mi.mesh
	var sk := _skeleton_of(mi)
	if sk != null:
		src = mi.bake_mesh_from_current_skeleton_pose()
	elif src.get_blend_shape_count() > 0:
		src = mi.bake_mesh_from_current_blend_shape_mix()
	if src == null:
		return
	var binds := PackedInt32Array()
	if sk != null and segs.has(sk):
		binds = _bind_bones(mi, sk)
	for s in src.get_surface_count():
		var arrays := _static_arrays(src.surface_get_arrays(s))
		var prim: int = src.surface_get_primitive_type(s)
		var mat := mi.get_active_material(s)
		var nm := "%s_%d" % [mi.name, s]
		var dom := PackedInt32Array()
		if not binds.is_empty() and prim == Mesh.PRIMITIVE_TRIANGLES:
			dom = _dominant_bones(mi.mesh.surface_get_arrays(s), binds)
			if dom.size() != (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
				dom = PackedInt32Array()
		if dom.is_empty():
			var sk_key := _static_key(mi, segs)
			_add(_part(sk_key[0], sk_key[1], sk_key[2]), prim, arrays, mat, mi.global_transform, nm)
			continue
		var seg: PackedInt32Array = segs[sk][0]
		var depth: PackedInt32Array = segs[sk][1]
		# Each triangle goes to the part most of its three vertices belong to.
		var idx := _indices(arrays)
		var idx_b := _blocks(idx)
		var dom_b := _blocks(dom)
		var group_of := {}  # cut bone -> local group
		var cuts: Array = []
		var tri_group := PackedInt32Array()
		for b in idx_b.size():
			var blk: PackedInt32Array = idx_b[b]
			var t := 0
			while t + 2 < blk.size():
				var cs: Array = []
				for k in 3:
					var v: int = blk[t + k]
					var bone: int = (dom_b[v / BLOCK] as PackedInt32Array)[v % BLOCK]
					cs.append(seg[bone] if bone >= 0 else -1)
				var cut: int = cs[0]
				if cs[1] == cs[2] and cs[1] != cs[0]:
					cut = cs[1]
				if not group_of.has(cut):
					group_of[cut] = cuts.size()
					cuts.append(cut)
				tri_group.append(group_of[cut])
				t += 3
		var parts: Array = [arrays]
		if cuts.size() > 1:
			parts = _gather(
				arrays, _blocks(arrays[Mesh.ARRAY_VERTEX]), idx_b, tri_group, cuts.size()
			)
		for g in parts.size():
			var cut: int = cuts[g] if g < cuts.size() else -1
			var key := "%d:%d" % [sk.get_instance_id(), cut]
			var d: int = depth[cut] if cut >= 0 else 0
			var cut_info: Array = _cut_axis(sk, cut, segs[sk]) if cut >= 0 else [null, null]
			_add(
				_part(key, d, cut_info), prim, parts[g], mat, mi.global_transform, "%s_%d" % [nm, g]
			)


# Surface arrays without skinning data or custom shader channels (the copy is static).
func _static_arrays(arrays: Array) -> Array:
	arrays[Mesh.ARRAY_BONES] = null
	arrays[Mesh.ARRAY_WEIGHTS] = null
	for c in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
		arrays[c] = null
	return arrays


func _indices(arrays: Array) -> PackedInt32Array:
	var idx := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		idx = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		for i in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
			idx.append(i)
	return idx


# One static mesh copy into part `pi`, at world transform `xform`.
func _add(pi: int, prim: int, arrays: Array, mat: Material, xform: Transform3D, nm: String) -> void:
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(prim, arrays)
	if am.get_surface_count() == 0:
		return
	if mat != null:
		am.surface_set_material(0, mat)
	var p := MeshInstance3D.new()
	p.name = nm
	p.mesh = am
	(pieces[pi] as Node3D).add_child(p)
	p.global_transform = xform
	var box: AABB = xform * am.get_aabb()
	part_box[pi] = box if part_box[pi] == null else (part_box[pi] as AABB).merge(box)


# A model with no skeleton and a single surface: cut it by one world grid instead.
func _grid_fallback(mis: Array) -> void:
	for c in root.get_children():
		c.queue_free()
	pieces.clear()
	part_of.clear()
	part_axis.clear()
	part_joint.clear()
	part_depth.clear()
	part_box.clear()
	var surfs: Array = []  # [arrays, prim, material, world xform, name]
	for m in mis:
		var mi := m as MeshInstance3D
		var src: Mesh = mi.mesh
		if _skeleton_of(mi) != null:
			src = mi.bake_mesh_from_current_skeleton_pose()
		elif src.get_blend_shape_count() > 0:
			src = mi.bake_mesh_from_current_blend_shape_mix()
		if src == null:
			continue
		for s in src.get_surface_count():
			surfs.append(
				[
					_static_arrays(src.surface_get_arrays(s)),
					src.surface_get_primitive_type(s),
					mi.get_active_material(s),
					mi.global_transform,
					"%s_%d" % [mi.name, s]
				]
			)
	if surfs.is_empty():
		return
	var box := AABB()
	var first := true
	for e in surfs:
		var sb: AABB = (e[3] as Transform3D) * _surface_aabb(e[0])
		box = sb if first else box.merge(sb)
		first = false
	var cell := maxf(maxf(box.size.x, box.size.y), box.size.z) / float(CELLS)
	var counts := Vector3i(
		clampi(ceili(box.size.x / cell - 1e-6), 1, CELLS),
		clampi(ceili(box.size.y / cell - 1e-6), 1, CELLS),
		clampi(ceili(box.size.z / cell - 1e-6), 1, CELLS)
	)
	var n := 0
	for e in surfs:
		var parts: Array = [e[0]]
		if int(e[1]) == Mesh.PRIMITIVE_TRIANGLES and cell > 0.0:
			parts = _split_grid(e[0], e[3], box.position, cell, counts)
		for k in parts.size():
			_add(
				_part("grid:%d" % n, 0, [null, null]),
				e[1],
				parts[k],
				e[2],
				e[3],
				"%s_%d" % [e[4], k]
			)
			n += 1


func _surface_aabb(arrays: Array) -> AABB:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bl := _blocks(pos)
	var lo: Vector3 = (bl[0] as PackedVector3Array)[0]
	var hi: Vector3 = lo
	for blk in bl:
		for p in blk as PackedVector3Array:
			lo = lo.min(p)
			hi = hi.max(p)
	return AABB(lo, hi - lo)


# --- Grid split ----------------------------------------------------------------------------
# Compiled guest loops copy the packed arrays they index into guest memory, and the host refuses a
# window over 4096 elements, so large arrays are read through blocks of at most BLOCK elements
# (`_blocks`, read as blocks[i / BLOCK][i % BLOCK]) and built with append only.

const CELLS := 3  # grid cells along the model's longest side
const BLOCK := 4092  # a multiple of 3 (triangles) and of 4 (tangents)


func _blocks(arr) -> Array:
	var out := []
	var n: int = arr.size()
	var i := 0
	while i < n:
		out.append(arr.slice(i, mini(i + BLOCK, n)))
		i += BLOCK
	return out


# Splits one triangle surface by the world grid (origin, cell size, counts): each triangle goes to
# the cell of its world-space centroid. Returns surface arrays, one per non-empty cell.
func _split_grid(
	arrays: Array, xform: Transform3D, origin: Vector3, cell: float, counts: Vector3i
) -> Array:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx := _indices(arrays)
	var pos_b := _blocks(pos)
	var idx_b := _blocks(idx)
	var cell_of := {}
	var tri_group := PackedInt32Array()
	for b in idx_b.size():
		var blk: PackedInt32Array = idx_b[b]
		var t := 0
		while t + 2 < blk.size():
			var cen := Vector3.ZERO
			for k in 3:
				var v: int = blk[t + k]
				cen += (pos_b[v / BLOCK] as PackedVector3Array)[v % BLOCK]
			var g: Vector3 = (xform * (cen / 3.0) - origin) / cell
			var key := Vector3i(
				clampi(int(floor(g.x)), 0, counts.x - 1),
				clampi(int(floor(g.y)), 0, counts.y - 1),
				clampi(int(floor(g.z)), 0, counts.z - 1)
			)
			if not cell_of.has(key):
				cell_of[key] = cell_of.size()
			tri_group.append(cell_of[key])
			t += 3
	if cell_of.size() < 2:
		return [arrays]
	return _gather(arrays, pos_b, idx_b, tri_group, cell_of.size())


# Builds one surface per group from the triangles whose tri_group entry names it, copying every
# per-vertex array the surface has and renumbering the vertices it uses.
func _gather(
	arrays: Array, pos_b: Array, idx_b: Array, tri_group: PackedInt32Array, ng: int
) -> Array:
	var remap: Array = []
	var verts: Array = []
	var tris: Array = []
	for g in ng:
		remap.append({})
		verts.append([])
		tris.append([])
	var tc_b := _blocks(tri_group)
	var tri_i := 0
	for b in idx_b.size():
		var blk: PackedInt32Array = idx_b[b]
		var t := 0
		while t + 2 < blk.size():
			var g: int = (tc_b[tri_i / BLOCK] as PackedInt32Array)[tri_i % BLOCK]
			var rm: Dictionary = remap[g]
			var vl: Array = verts[g]
			var tl: Array = tris[g]
			for k in 3:
				var v: int = blk[t + k]
				if not rm.has(v):
					rm[v] = vl.size()
					vl.append(v)
				tl.append(rm[v])
			tri_i += 1
			t += 3
	# Gather every per-vertex array the surface has.
	var out: Array = []
	var nrm_b := _blocks(arrays[Mesh.ARRAY_NORMAL]) if arrays[Mesh.ARRAY_NORMAL] != null else []
	var tan_b := _blocks(arrays[Mesh.ARRAY_TANGENT]) if arrays[Mesh.ARRAY_TANGENT] != null else []
	var col_b := _blocks(arrays[Mesh.ARRAY_COLOR]) if arrays[Mesh.ARRAY_COLOR] != null else []
	var uv_b := _blocks(arrays[Mesh.ARRAY_TEX_UV]) if arrays[Mesh.ARRAY_TEX_UV] != null else []
	var uv2_b := _blocks(arrays[Mesh.ARRAY_TEX_UV2]) if arrays[Mesh.ARRAY_TEX_UV2] != null else []
	for g in ng:
		var vl: Array = verts[g]
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		var p := PackedVector3Array()
		var nrm := PackedVector3Array()
		var tan := PackedFloat32Array()
		var col := PackedColorArray()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		for v in vl:
			var bi: int = v / BLOCK
			var o: int = v % BLOCK
			p.append((pos_b[bi] as PackedVector3Array)[o])
			if not nrm_b.is_empty():
				nrm.append((nrm_b[bi] as PackedVector3Array)[o])
			if not col_b.is_empty():
				col.append((col_b[bi] as PackedColorArray)[o])
			if not uv_b.is_empty():
				uv.append((uv_b[bi] as PackedVector2Array)[o])
			if not uv2_b.is_empty():
				uv2.append((uv2_b[bi] as PackedVector2Array)[o])
			if not tan_b.is_empty():
				var tv: int = v * 4
				var tb: PackedFloat32Array = tan_b[tv / BLOCK]
				var to: int = tv % BLOCK
				tan.append(tb[to])
				tan.append(tb[to + 1])
				tan.append(tb[to + 2])
				tan.append(tb[to + 3])
		a[Mesh.ARRAY_VERTEX] = p
		if not nrm_b.is_empty():
			a[Mesh.ARRAY_NORMAL] = nrm
		if not tan_b.is_empty():
			a[Mesh.ARRAY_TANGENT] = tan
		if not col_b.is_empty():
			a[Mesh.ARRAY_COLOR] = col
		if not uv_b.is_empty():
			a[Mesh.ARRAY_TEX_UV] = uv
		if not uv2_b.is_empty():
			a[Mesh.ARRAY_TEX_UV2] = uv2
		a[Mesh.ARRAY_INDEX] = PackedInt32Array(tris[g])
		out.append(a)
	return out


# Placement (Explode.layout in lean/Explode.lean): parts with fewer cuts above them first, then
# nearest the model centre, larger first on ties; each moves out along its direction by the
# smallest candidate amount at which its box is `gap` away, on some axis, from every box placed
# before it. Placed pieces never move again, so every pair is checked once, when the later one is
# placed.
func _layout() -> void:
	var all := AABB(centres[0] - halves[0], halves[0] * 2.0)
	for i in centres.size():
		all = all.merge(AABB(centres[i] - halves[i], halves[i] * 2.0))
	var centre := all.get_center()
	var radius := maxf(all.size.length() * 0.5, 1e-6)
	gap = GAP * radius
	var n := centres.size()
	var keys: Array = []
	for i in n:
		var d: float = ((centres[i] as Vector3) - centre).length()
		var hv: Vector3 = halves[i]
		keys.append([part_depth[i], d, -hv.x * hv.y * hv.z, i])
	keys.sort()
	var c2: Array = []
	var h2: Array = []
	var p2: Array = []
	var j2: Array = []
	var k2: Array = []
	for k in keys:
		var i: int = k[3]
		c2.append(centres[i])
		h2.append(halves[i])
		p2.append(pieces[i])
		j2.append(part_axis[i])
		k2.append(part_joint[i])
	centres = c2
	halves = h2
	pieces = p2
	dirs.clear()
	moves.clear()
	var placed: Array = []
	for i in n:
		var c: Vector3 = centres[i]
		# Along the part's main chain, plus a sideways push away from the body's centre line so
		# paired limbs spread apart instead of queueing behind each other; else out from the centre.
		var off: Vector3 = c - centre
		if j2[i] != null:
			off = (j2[i] as Vector3).normalized()
			var lat: Vector3 = (k2[i] as Vector3) - centre
			lat -= off * lat.dot(off)
			if lat.length() > 0.02 * radius:
				off += lat.normalized() * 0.5
		var v: Vector3 = (
			off.normalized() * radius
			if off.length() > 1e-6 * radius
			else _spread_dir(i, n) * radius
		)
		dirs.append(v)
		var t := _place(c, halves[i], v, placed)
		moves.append(t)
		placed.append(c + v * t)


# Smallest candidate t >= 0 at which a box (c, h) moved by t * v is free of every placed box.
func _place(c: Vector3, h: Vector3, v: Vector3, placed: Array) -> float:
	var cands: Array = [0.0]
	for j in placed.size():
		var pc: Vector3 = placed[j]
		var ph: Vector3 = halves[j]
		for k in 3:
			if v[k] == 0.0:
				continue
			var d: float = c[k] - pc[k]
			# Candidates aim at a slightly larger gap than _free() demands, so the float32
			# rounding of positions (Vector3 in a single-precision build) cannot leave a box
			# just inside the gap; the printed and proved gap is `gap` itself.
			var hh: float = ph[k] + h[k] + gap * AIM
			var up := maxf((hh - d) / v[k], (-hh - d) / v[k])
			if up >= 0.0:
				cands.append(up)
	cands.sort()
	for t in cands:
		if _free(c + v * float(t), h, placed):
			return t
	# Not reached in exact arithmetic (the largest candidate is free); keep going outwards.
	push_warning("model_explode: no candidate was free, moving further out")
	var t2: float = cands[cands.size() - 1]
	for tries in 60:
		t2 = t2 * 1.5 + 1e-6
		if _free(c + v * t2, h, placed):
			return t2
	return t2


func _free(c: Vector3, h: Vector3, placed: Array) -> bool:
	for j in placed.size():
		var pc: Vector3 = placed[j]
		var ph: Vector3 = halves[j]
		var apart := false
		for k in 3:
			if absf(c[k] - pc[k]) >= ph[k] + h[k] + gap * KEEP:
				apart = true
				break
		if not apart:
			return false
	return true


# Point i of n on a Fibonacci sphere: well spread unit directions.
func _spread_dir(i: int, n: int) -> Vector3:
	var y := 1.0 - 2.0 * (float(i) + 0.5) / float(maxi(n, 1))
	var r := sqrt(maxf(0.0, 1.0 - y * y))
	var phi := float(i) * 2.399963229728653
	return Vector3(cos(phi) * r, y, sin(phi) * r)


# The layout in the format `lake exe explode_check` reads, one console line each, prefixed
# "EXPLODE " so a test can cut them out of the browser log.
func print_layout() -> void:
	print("EXPLODE gap %.17f" % gap)
	for i in centres.size():
		var c: Vector3 = centres[i]
		var h: Vector3 = halves[i]
		var v: Vector3 = dirs[i]
		print(
			(
				"EXPLODE piece %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f"
				% [c.x, c.y, c.z, h.x, h.y, h.z, v.x, v.y, v.z, moves[i]]
			)
		)
	print("EXPLODE end %d" % centres.size())
