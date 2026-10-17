extends RefCounted
# Exploded view that takes a model apart along the edges its artist made, and no others.
#
# Pieces: every connected shell of the model is one piece, a shell being the triangles that share
# vertices, across all meshes and materials, welded by world position (UV and material seams
# split vertices but are not edges of the shape). Nothing is cut, so every piece edge is an edge
# the artist made: a jacket comes off the body whole, the hair off the head, a shoe off the foot.
# A shell with less than MIN_SHARE of the model's triangles (an eye, a button, one hair card) is
# not a piece of its own: the small shells of one mesh travel together. Copies are static, taken
# at the current pose (skinned meshes through bake_mesh_from_current_skeleton_pose(),
# blend-shaped ones through bake_mesh_from_current_blend_shape_mix()).
#
# Joint cuts, only where the artist made no edges: a skinned shell with at least CUT_SHARE of the
# triangles (a body modelled in one piece) is cut at its skeleton's big branches (legs, arms,
# neck, waist: a branch holding at least BRANCH_SHARE of that shell), like an action figure. Each
# cut is a flat plane across the limb at the joint, square to the limb; two sibling parts meet on
# the plane halfway between their joints. Triangles crossing a plane are split exactly on it, so
# the cut edge is straight, and each opening is closed with a flat cap. No bone names are read.
#
# Layout: piece i has a world-space box (centre c_i, half extents h_i) and a direction v_i out
# from the model centre. Pieces are placed nearest the centre first, larger first on ties; each
# moves along v_i by the smallest amount at which its box is at least `gap` away, on some axis,
# from every box placed before it (so the core stays put and outer pieces move only as far as
# they must). lean/Explode.lean defines that placement over exact rationals and proves
# (layout_sound, separated_disjoint) that no two boxes of a layout share a point, for any pieces,
# directions and order, so no two pieces intersect. `lake exe explode_check` re-checks a layout
# printed by `print_layout()` in exact arithmetic.
#
# The guarantee is for the resting layout; during the short move-out animation pieces may pass
# through each other.

const WIRE_GROUP := "vsk_web_wire"
const GAP := 0.03  # minimum distance between boxes, as a share of the model radius
const MOVE_TIME := 0.35
const MIN_SHARE := 0.01  # a shell with at least this share of the triangles is its own piece
const WELD := 1e-5  # vertices closer than this share of the model size are one vertex
const CUT_SHARE := 0.5  # a skinned shell with at least this share of the triangles gets joint cuts
const BRANCH_SHARE := 0.04  # a skeleton branch with at least this share of that shell is a part
const CAP_COLOR := Color(0.62, 0.6, 0.58)
# Placement works with a gap slightly above GAP: candidates aim at AIM x gap, a spot counts as
# free at KEEP x gap; float32 rounding (about 1e-7 of the model size) stays far below the margin.
const AIM := 1.002
const KEEP := 1.001
# Compiled guest loops copy the packed arrays they index into guest memory, and the host refuses a
# window over 4096 elements, so large arrays are read through blocks of at most BLOCK elements
# (`_blocks`, read as blocks[i / BLOCK][i % BLOCK]) and built with append only.
const BLOCK := 4092  # a multiple of 3 (triangles) and of 4 (tangents)

var root: Node3D  # holds the piece copies while exploded
var hidden: Array = []  # nodes this script hid, restored by implode()
var centres: Array = []  # world box centres (Vector3)
var halves: Array = []  # world box half extents (Vector3)
var dirs: Array = []  # directions (Vector3)
var pieces: Array = []  # Node3D per piece, holding its MeshInstance3D copies
var moves: Array = []  # how far each piece moves along its direction (float)
var gap := 0.0
var part_of := {}  # piece key -> index into pieces
var part_box: Array = []  # world AABB per piece
var part_depth: Array = []  # joint cuts above the piece (0 for whole shells)
var part_axis: Array = []  # world direction of a cut part's limb (Vector3), or null
var part_joint: Array = []  # world position of a cut part's joint (Vector3), or null


# Builds the pieces and moves them out. `models` are the loaded model roots; `parent` receives the
# piece root (it must not be inside a model, so the model's own animation does not move pieces).
func explode(models: Array, parent: Node, animate := true) -> void:
	implode()
	root = Node3D.new()
	root.name = "ExplodedPieces"
	parent.add_child(root)
	# [arrays, prim, material, world xform, name, owner id, skeleton or null, dominant bones]
	var surfs: Array = []
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
			_collect(mi, surfs)
			if mi.visible:
				mi.visible = false
				hidden.append(mi)
	if surfs.is_empty():
		return
	_split_shells(surfs)
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
	part_box.clear()
	part_depth.clear()
	part_axis.clear()
	part_joint.clear()


func is_exploded() -> bool:
	return root != null


func _ancestors_visible(n: Node, stop: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != stop.get_parent():
		if p is Node3D and not (p as Node3D).visible:
			return false
		p = p.get_parent()
	return true


# Static copies of `mi`'s surfaces at the current pose.
func _collect(mi: MeshInstance3D, surfs: Array) -> void:
	var src: Mesh = mi.mesh
	var sk := _skeleton_of(mi)
	var binds := PackedInt32Array()
	if sk != null:
		binds = _bind_bones(mi, sk)
		src = mi.bake_mesh_from_current_skeleton_pose()
	elif src.get_blend_shape_count() > 0:
		src = mi.bake_mesh_from_current_blend_shape_mix()
	if src == null:
		return
	for s in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		for c in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			arrays[c] = null
		var nv: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if nv == 0:
			continue
		var dom := PackedInt32Array()
		if sk != null and s < mi.mesh.get_surface_count():
			dom = _dominant_bones(mi.mesh.surface_get_arrays(s), binds)
			if dom.size() != nv:
				dom = PackedInt32Array()
		surfs.append(
			[
				arrays,
				src.surface_get_primitive_type(s),
				mi.get_active_material(s),
				mi.global_transform,
				"%s_%d" % [mi.name, s],
				mi.get_instance_id(),
				sk if not dom.is_empty() else null,
				dom
			]
		)


func _indices(arrays: Array) -> PackedInt32Array:
	var idx := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		idx = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		for i in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
			idx.append(i)
	return idx


# --- Shells ---------------------------------------------------------------------------------


func _find(up: Dictionary, a: int) -> int:
	var r := a
	while up.has(r):
		r = up[r]
	while up.has(a):  # path compression
		var n: int = up[a]
		up[a] = r
		a = n
	return r


func _union(up: Dictionary, a: int, b: int) -> void:
	var ra := _find(up, a)
	var rb := _find(up, b)
	if ra != rb:
		up[maxi(ra, rb)] = mini(ra, rb)


# Finds the shells of all surfaces together and emits one piece per shell (small shells of one
# mesh together).
func _split_shells(surfs: Array) -> void:
	var box := AABB()
	var first := true
	for e in surfs:
		var sb: AABB = (e[3] as Transform3D) * _surface_aabb(e[0])
		box = sb if first else box.merge(sb)
		first = false
	var q := maxf(box.size.length() * WELD, 1e-9)
	# Weld: one id per distinct world position (rounded to q); per surface, the id of each vertex.
	var weld := {}
	var vid: Array = []  # per surface: blocks of weld ids
	var tris: Array = []  # per surface: blocks of indices (triangles only)
	for e in surfs:
		var xf: Transform3D = e[3]
		var ids := PackedInt32Array()
		for blk in _blocks(e[0][Mesh.ARRAY_VERTEX]):
			for p in blk as PackedVector3Array:
				var w: Vector3 = xf * p
				var key := Vector3i(roundi(w.x / q), roundi(w.y / q), roundi(w.z / q))
				if not weld.has(key):
					weld[key] = weld.size()
				ids.append(weld[key])
		vid.append(_blocks(ids))
		tris.append(_blocks(_indices(e[0])) if int(e[1]) == Mesh.PRIMITIVE_TRIANGLES else [])
	# Union the three corners of every triangle.
	var up := {}
	var total := 0
	for si in surfs.size():
		var vb: Array = vid[si]
		for blk in tris[si]:
			var t := 0
			var ib := blk as PackedInt32Array
			while t + 2 < ib.size():
				var a: int = (vb[ib[t] / BLOCK] as PackedInt32Array)[ib[t] % BLOCK]
				var b: int = (vb[ib[t + 1] / BLOCK] as PackedInt32Array)[ib[t + 1] % BLOCK]
				var c: int = (vb[ib[t + 2] / BLOCK] as PackedInt32Array)[ib[t + 2] % BLOCK]
				_union(up, a, b)
				_union(up, b, c)
				total += 1
				t += 3
	# Triangles per shell.
	var size_of := {}
	var shell_tris: Array = []  # per surface: shell root of each triangle
	for si in surfs.size():
		var vb: Array = vid[si]
		var roots := PackedInt32Array()
		for blk in tris[si]:
			var t := 0
			var ib := blk as PackedInt32Array
			while t + 2 < ib.size():
				var r := _find(up, (vb[ib[t] / BLOCK] as PackedInt32Array)[ib[t] % BLOCK])
				roots.append(r)
				size_of[r] = int(size_of.get(r, 0)) + 1
				t += 3
		shell_tris.append(roots)
	var big := maxf(1.0, MIN_SHARE * float(total))
	# Shells that get joint cuts: skinned, and most of the model.
	var cut_root := {}  # shell root -> Skeleton3D
	for si in surfs.size():
		var e: Array = surfs[si]
		if e[6] == null:
			continue
		for r in shell_tris[si] as PackedInt32Array:
			if float(size_of[r]) >= CUT_SHARE * float(total) and not cut_root.has(r):
				cut_root[r] = e[6]
	var rigs := _rigs(surfs, tris, shell_tris, cut_root)
	var caps := {}  # cut pair -> [part, part, plane normal toward the second, cut edges, rig]
	# Emit: each surface split by piece key.
	for si in surfs.size():
		var e: Array = surfs[si]
		var cuts_here := false
		if e[6] != null and rigs.has(e[6]):
			for r in shell_tris[si] as PackedInt32Array:
				if cut_root.has(r):
					cuts_here = true
					break
		if cuts_here:
			_emit_cut(
				e, vid[si], tris[si], shell_tris[si], cut_root, rigs[e[6]], size_of, big, caps
			)
			continue
		if tris[si].is_empty():
			_add(_part("mesh:%d" % e[5]), e[1], e[0], e[2], e[3], e[4])
			continue
		var keys: Array = []
		var local := {}
		var tri_group := PackedInt32Array()
		for r in shell_tris[si] as PackedInt32Array:
			var k := "shell:%d" % r if float(size_of[r]) >= big else "small:%d" % e[5]
			if not local.has(k):
				local[k] = keys.size()
				keys.append(k)
			tri_group.append(local[k])
		var parts: Array = [e[0]]
		if keys.size() > 1:
			parts = _gather(
				e[0], _blocks(e[0][Mesh.ARRAY_VERTEX]), tris[si], tri_group, keys.size()
			)
		for g in parts.size():
			_add(_part(keys[g]), e[1], parts[g], e[2], e[3], "%s_%d" % [e[4], g])
	_emit_caps(caps, rigs)


# --- Joint cuts -----------------------------------------------------------------------------


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


func _bone_world(sk: Skeleton3D, bone: int) -> Vector3:
	return sk.global_transform * sk.get_bone_global_pose(bone).origin


# Per skeleton with a cut shell, a rig: {seg, depth, root, parent part, children parts, axis,
# joint, reach}. seg[bone] is the part a bone belongs to (the bone that starts it). A bone starts
# a part when its subtree holds BRANCH_SHARE of the cut shell's skin and its parent has two such
# subtrees. A part's axis runs down its main chain (shoulder to elbow, hip to knee); its joint is
# where the limb's own skin starts: the cut bone's head, or further down the chain past bones that
# are short or hold little skin (a clavicle), so an arm comes off at the shoulder, not the neck.
func _rigs(surfs: Array, tris: Array, shell_tris: Array, cut_root: Dictionary) -> Dictionary:
	var mass := {}
	for si in surfs.size():
		var sk = surfs[si][6]
		if sk == null or not cut_root.values().has(sk):
			continue
		if not mass.has(sk):
			var z := PackedInt32Array()
			z.resize((sk as Skeleton3D).get_bone_count())
			mass[sk] = z
		var m: PackedInt32Array = mass[sk]
		var dom_b := _blocks(surfs[si][7])
		var roots: PackedInt32Array = shell_tris[si]
		var ti := 0
		for blk in tris[si]:
			var ib := blk as PackedInt32Array
			var t := 0
			while t + 2 < ib.size():
				if cut_root.has(roots[ti]):
					for k in 3:
						var bone: int = (dom_b[ib[t + k] / BLOCK] as PackedInt32Array)[
							ib[t + k] % BLOCK
						]
						if bone >= 0 and bone < m.size():
							m[bone] += 1
				ti += 1
				t += 3
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
			var p := skel.get_bone_parent(order[j])
			if p >= 0:
				sub[p] += sub[order[j]]
		var thr := maxf(1.0, BRANCH_SHARE * float(total))
		var seg := PackedInt32Array()
		seg.resize(skel.get_bone_count())
		var depth := PackedInt32Array()
		depth.resize(skel.get_bone_count())
		var root := -1
		var up := {}  # part -> parent part
		var kids := {}  # part -> child parts
		for b in order:
			var p := skel.get_bone_parent(b)
			var cut := false
			if p >= 0 and float(sub[b]) >= thr:
				var bigs := 0
				for c in skel.get_bone_children(p):
					if float(sub[c]) >= thr:
						bigs += 1
				cut = bigs >= 2
			if p < 0:
				seg[b] = b
				if root < 0 or sub[b] > sub[root]:
					root = b
				kids[b] = []
			elif cut:
				seg[b] = b
				depth[b] = depth[p] + 1
				up[b] = seg[p]
				kids[b] = []
				(kids[seg[p]] as Array).append(b)
			else:
				seg[b] = seg[p]
				depth[b] = depth[p]
		var axis := {}
		var joint := {}
		for c in up:
			var chain: Array = [c]
			var half := 0.5 * float(sub[c])
			while true:
				var next := -1
				for k in skel.get_bone_children(chain[chain.size() - 1]):
					if seg[k] == c and float(sub[k]) >= half and (next < 0 or sub[k] > sub[next]):
						next = k
				if next < 0:
					break
				chain.append(next)
			var j0 := _bone_world(skel, c)
			var a := _bone_world(skel, chain[chain.size() - 1]) - j0
			if a.length() <= 1e-9:
				a = j0 - _bone_world(skel, skel.get_bone_parent(c))
			if a.length() <= 1e-9:
				continue
			# Move the joint down the chain past bones that are short or hold little of the part's
			# skin (a clavicle, a shoulder bone rooted on the spine), at most two.
			var j := j0
			var at := 0
			var full := a.length()
			while at < 2 and at + 2 < chain.size():
				var bone_len := (
					(_bone_world(skel, chain[at + 1]) - _bone_world(skel, chain[at])).length()
				)
				if bone_len >= 0.25 * full and float(m[chain[at]]) >= 0.15 * float(sub[c]):
					break
				at += 1
			if at > 0:
				j = _bone_world(skel, chain[at])
				a = _bone_world(skel, chain[chain.size() - 1]) - j
			if a.length() <= 1e-9:
				continue
			axis[c] = a.normalized()
			joint[c] = j
		out[sk] = {
			"id": skel.get_instance_id(),
			"seg": seg,
			"depth": depth,
			"root": root,
			"up": up,
			"kids": kids,
			"axis": axis,
			"joint": joint,
			"reach": {},
		}
	# How far from its limb line a part and everything below it reaches: a body point beyond a joint plane joins that part
	# only within this distance of the limb, so the far side of the body is never taken.
	for si in surfs.size():
		var sk = surfs[si][6]
		if sk == null or not out.has(sk):
			continue
		var rig: Dictionary = out[sk]
		var xf: Transform3D = surfs[si][3]
		var pos_b := _blocks(surfs[si][0][Mesh.ARRAY_VERTEX])
		var dom_b := _blocks(surfs[si][7])
		var reach: Dictionary = rig["reach"]
		for b in pos_b.size():
			var pb := pos_b[b] as PackedVector3Array
			var db := dom_b[b] as PackedInt32Array
			for o in pb.size():
				var bone: int = db[o]
				if bone < 0:
					continue
				# The point counts toward its part and every part above it, so a part's reach
				# covers its whole branch (the spine's reach includes the arms).
				var part: int = (rig["seg"] as PackedInt32Array)[bone]
				var x: Vector3 = xf * pb[o]
				while part >= 0:
					if rig["axis"].has(part):
						reach[part] = maxf(float(reach.get(part, 0.0)), _lateral(x, rig, part))
					part = rig["up"].get(part, -1)
	return out


func _lateral(x: Vector3, rig: Dictionary, part: int) -> float:
	var n: Vector3 = rig["axis"][part]
	var d: Vector3 = x - (rig["joint"][part] as Vector3)
	return (d - n * d.dot(n)).length()


# The part a body point at world position x belongs to, by the planes alone: start at the root
# part and step into the nearest child part whose joint plane the point is beyond (and within
# that part's reach), until there is none. The same planes split the triangles, so the parts
# meet exactly on the cut.
func _label(x: Vector3, rig: Dictionary) -> int:
	var axis: Dictionary = rig["axis"]
	var joint: Dictionary = rig["joint"]
	var part: int = rig["root"]
	while true:
		var best := -1
		var best_d := INF
		for c in rig["kids"].get(part, []):
			if not axis.has(c):
				continue
			if (x - (joint[c] as Vector3)).dot(axis[c]) <= 0.0:
				continue
			if _lateral(x, rig, c) > 1.1 * float(rig["reach"].get(c, 0.0)):
				continue
			var d := x.distance_to(joint[c])
			if d < best_d:
				best_d = d
				best = c
		if best < 0:
			break
		part = best
	return part


# The plane between parts a and b, as [point, normal toward b], or [] when there is none: a
# joint plane between a part and its child, else the plane halfway between two joints.
func _plane(a: int, b: int, rig: Dictionary) -> Array:
	var axis: Dictionary = rig["axis"]
	var joint: Dictionary = rig["joint"]
	if rig["up"].get(b, -1) == a and axis.has(b):
		return [joint[b], axis[b]]
	if rig["up"].get(a, -1) == b and axis.has(a):
		return [joint[a], -(axis[a] as Vector3)]
	if joint.has(a) and joint.has(b):
		var ab: Vector3 = (joint[b] as Vector3) - (joint[a] as Vector3)
		if ab.length() > 1e-9:
			return [((joint[a] as Vector3) + (joint[b] as Vector3)) * 0.5, ab.normalized()]
	return []


func _cut_key(rig: Dictionary, part: int) -> String:
	return "cut:%d:%d" % [rig["id"], part]


func _cut_part(rig: Dictionary, part: int) -> int:
	return _part(
		_cut_key(rig, part),
		(rig["depth"] as PackedInt32Array)[part],
		rig["axis"].get(part, null),
		rig["joint"].get(part, null)
	)


# One surface with joint cuts: triangles of a cut shell are labelled by part and split exactly on
# the plane between two parts; other triangles go to their shell's piece. Cut edges are recorded
# in `caps` for _emit_caps.
func _emit_cut(
	e: Array,
	vb: Array,
	tb: Array,
	roots: PackedInt32Array,
	cut_root: Dictionary,
	rig: Dictionary,
	size_of: Dictionary,
	big: float,
	caps: Dictionary
) -> void:
	var arrays: Array = e[0]
	var xf: Transform3D = e[3]
	var pos_b := _blocks(arrays[Mesh.ARRAY_VERTEX])
	var nrm_b := _blocks(arrays[Mesh.ARRAY_NORMAL]) if arrays[Mesh.ARRAY_NORMAL] != null else []
	var tan_b := _blocks(arrays[Mesh.ARRAY_TANGENT]) if arrays[Mesh.ARRAY_TANGENT] != null else []
	var col_b := _blocks(arrays[Mesh.ARRAY_COLOR]) if arrays[Mesh.ARRAY_COLOR] != null else []
	var uv_b := _blocks(arrays[Mesh.ARRAY_TEX_UV]) if arrays[Mesh.ARRAY_TEX_UV] != null else []
	var uv2_b := _blocks(arrays[Mesh.ARRAY_TEX_UV2]) if arrays[Mesh.ARRAY_TEX_UV2] != null else []
	# Output arrays: the old vertices, then the new ones made on cut edges.
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	for blk in pos_b:
		pos.append_array(blk)
	for blk in nrm_b:
		nrm.append_array(blk)
	for blk in tan_b:
		tan.append_array(blk)
	for blk in col_b:
		col.append_array(blk)
	for blk in uv_b:
		uv.append_array(blk)
	for blk in uv2_b:
		uv2.append_array(blk)
	var label := {}  # vertex -> part
	var made := {}  # "a b pair" -> new vertex index
	var idx := PackedInt32Array()
	var keys: Array = []
	var local := {}
	var tri_group := PackedInt32Array()
	var ti := 0
	for blk in tb:
		var ib := blk as PackedInt32Array
		var t := 0
		while t + 2 < ib.size():
			var r: int = roots[ti]
			ti += 1
			var tri := [ib[t], ib[t + 1], ib[t + 2]]
			t += 3
			if not cut_root.has(r):
				var k := "shell:%d" % r if float(size_of[r]) >= big else "small:%d" % e[5]
				_tri_out(tri, k, idx, keys, local, tri_group)
				continue
			var lab: Array = []
			for v in tri:
				if not label.has(v):
					label[v] = _label(xf * (pos_b[v / BLOCK] as PackedVector3Array)[v % BLOCK], rig)
				lab.append(label[v])
			if lab[0] == lab[1] and lab[1] == lab[2]:
				_tri_out(tri, _cut_key(rig, lab[0]), idx, keys, local, tri_group)
				_cut_part(rig, lab[0])
				continue
			# Marching triangles over the part labels: every edge whose ends differ is cut once,
			# where it crosses the plane between the two parts, so neighbouring triangles agree
			# and the cut edges chain into closed loops.
			var m := []  # cut vertex on edge i (corner i to corner i+1), or -1
			var wk := []  # its weld key
			for i in 3:
				var u: int = tri[i]
				var w: int = tri[(i + 1) % 3]
				if lab[i] == lab[(i + 1) % 3]:
					m.append(-1)
					wk.append("")
					continue
				var la: int = lab[i]
				var lb: int = lab[(i + 1) % 3]
				var pair := "%d:%d|%d" % [rig["id"], mini(la, lb), maxi(la, lb)]
				var tt := 0.5
				var pl := _plane(mini(la, lb), maxi(la, lb), rig)
				if not pl.is_empty():
					var su: float = (
						(
							xf * (pos_b[u / BLOCK] as PackedVector3Array)[u % BLOCK]
							- (pl[0] as Vector3)
						)
						. dot(pl[1])
					)
					var sw: float = (
						(
							xf * (pos_b[w / BLOCK] as PackedVector3Array)[w % BLOCK]
							- (pl[0] as Vector3)
						)
						. dot(pl[1])
					)
					if (su < 0.0) != (sw < 0.0):
						tt = su / (su - sw)
				m.append(_edge_vertex(u, w, tt, pair, made, pos, nrm, tan, col, uv, uv2))
				wk.append(_weld_edge(u, w, vb))
			if lab[0] != lab[1] and lab[1] != lab[2] and lab[0] != lab[2]:
				# Three parts: each corner keeps the quad up to the triangle's centre.
				var cv := _centre_vertex(tri, pos, nrm, tan, col, uv, uv2)
				var ck := "c %d %d %d" % [e[5], tri[0], tri[1]]
				for i in 3:
					var prev := (i + 2) % 3
					var key := _cut_key(rig, lab[i])
					_tri_out([tri[i], m[i], cv], key, idx, keys, local, tri_group)
					_tri_out([tri[i], cv, m[prev]], key, idx, keys, local, tri_group)
					_cut_part(rig, lab[i])
					_cap_edge(
						caps, rig, lab[i], lab[(i + 1) % 3], wk[i], ck, xf * pos[m[i]], xf * pos[cv]
					)
				continue
			# Two parts: corner `lone_i` is alone; edges lone_i and lone_i + 2 are cut.
			var lone_i := 0
			if lab[1] != lab[0] and lab[1] != lab[2]:
				lone_i = 1
			elif lab[2] != lab[0] and lab[2] != lab[1]:
				lone_i = 2
			var A: int = tri[lone_i]
			var B: int = tri[(lone_i + 1) % 3]
			var C: int = tri[(lone_i + 2) % 3]
			var ab: int = m[lone_i]
			var ca: int = m[(lone_i + 2) % 3]
			var lone := _cut_key(rig, lab[lone_i])
			var rest := _cut_key(rig, lab[(lone_i + 1) % 3])
			_tri_out([A, ab, ca], lone, idx, keys, local, tri_group)
			_tri_out([ab, B, C], rest, idx, keys, local, tri_group)
			_tri_out([ab, C, ca], rest, idx, keys, local, tri_group)
			_cut_part(rig, lab[lone_i])
			_cut_part(rig, lab[(lone_i + 1) % 3])
			_cap_edge(
				caps,
				rig,
				lab[lone_i],
				lab[(lone_i + 1) % 3],
				wk[lone_i],
				wk[(lone_i + 2) % 3],
				xf * pos[ab],
				xf * pos[ca]
			)
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = pos
	if not nrm_b.is_empty():
		out[Mesh.ARRAY_NORMAL] = nrm
	if not tan_b.is_empty():
		out[Mesh.ARRAY_TANGENT] = tan
	if not col_b.is_empty():
		out[Mesh.ARRAY_COLOR] = col
	if not uv_b.is_empty():
		out[Mesh.ARRAY_TEX_UV] = uv
	if not uv2_b.is_empty():
		out[Mesh.ARRAY_TEX_UV2] = uv2
	out[Mesh.ARRAY_INDEX] = idx
	var parts: Array = _gather(out, _blocks(pos), _blocks(idx), tri_group, keys.size())
	for g in parts.size():
		var pi: int = part_of[keys[g]] if part_of.has(keys[g]) else _part(keys[g])
		_add(pi, e[1], parts[g], e[2], xf, "%s_%d" % [e[4], g])


# Records one cut edge between parts a and b for the caps.
func _cap_edge(
	caps: Dictionary,
	rig: Dictionary,
	a: int,
	b: int,
	ka: String,
	kb: String,
	pa: Vector3,
	pb: Vector3
) -> void:
	var lo := mini(a, b)
	var hi := maxi(a, b)
	var pair := "%d:%d|%d" % [rig["id"], lo, hi]
	if not caps.has(pair):
		caps[pair] = [lo, hi, null, [], rig]
	(caps[pair][3] as Array).append([ka, kb, pa, pb])


# A new vertex at the centre of a triangle, every attribute averaged.
func _centre_vertex(
	tri: Array,
	pos: PackedVector3Array,
	nrm: PackedVector3Array,
	tan: PackedFloat32Array,
	col: PackedColorArray,
	uv: PackedVector2Array,
	uv2: PackedVector2Array
) -> int:
	var a: int = tri[0]
	var b: int = tri[1]
	var c: int = tri[2]
	var i := pos.size()
	pos.append((pos[a] + pos[b] + pos[c]) / 3.0)
	if not nrm.is_empty():
		nrm.append((nrm[a] + nrm[b] + nrm[c]).normalized())
	if not tan.is_empty():
		var tv := Vector3.ZERO
		for v in tri:
			tv += Vector3(tan[v * 4], tan[v * 4 + 1], tan[v * 4 + 2])
		tv = tv.normalized()
		tan.append(tv.x)
		tan.append(tv.y)
		tan.append(tv.z)
		tan.append(tan[a * 4 + 3])
	if not col.is_empty():
		col.append((col[a] + col[b] + col[c]) / 3.0)
	if not uv.is_empty():
		uv.append((uv[a] + uv[b] + uv[c]) / 3.0)
	if not uv2.is_empty():
		uv2.append((uv2[a] + uv2[b] + uv2[c]) / 3.0)
	return i


func _tri_out(
	tri: Array,
	key: String,
	idx: PackedInt32Array,
	keys: Array,
	local: Dictionary,
	groups: PackedInt32Array
) -> void:
	if not local.has(key):
		local[key] = keys.size()
		keys.append(key)
	idx.append(tri[0])
	idx.append(tri[1])
	idx.append(tri[2])
	groups.append(local[key])


func _weld_edge(a: int, b: int, vb: Array) -> String:
	var wa: int = (vb[a / BLOCK] as PackedInt32Array)[a % BLOCK]
	var wb: int = (vb[b / BLOCK] as PackedInt32Array)[b % BLOCK]
	return "%d %d" % [mini(wa, wb), maxi(wa, wb)]


# The vertex where edge a-b crosses a plane, at share t from a, made once per edge and plane;
# every attribute is interpolated.
func _edge_vertex(
	a: int,
	b: int,
	t: float,
	pair: String,
	made: Dictionary,
	pos: PackedVector3Array,
	nrm: PackedVector3Array,
	tan: PackedFloat32Array,
	col: PackedColorArray,
	uv: PackedVector2Array,
	uv2: PackedVector2Array
) -> int:
	var key := "%d %d %s" % [mini(a, b), maxi(a, b), pair]
	if made.has(key):
		return made[key]
	if a > b:
		var s := a
		a = b
		b = s
		t = 1.0 - t
	var i := pos.size()
	pos.append(pos[a].lerp(pos[b], t))
	if not nrm.is_empty():
		nrm.append(nrm[a].lerp(nrm[b], t).normalized())
	if not tan.is_empty():
		var ta := Vector3(tan[a * 4], tan[a * 4 + 1], tan[a * 4 + 2])
		var tb := Vector3(tan[b * 4], tan[b * 4 + 1], tan[b * 4 + 2])
		var tv := ta.lerp(tb, t).normalized()
		tan.append(tv.x)
		tan.append(tv.y)
		tan.append(tv.z)
		tan.append(tan[a * 4 + 3])
	if not col.is_empty():
		col.append(col[a].lerp(col[b], t))
	if not uv.is_empty():
		uv.append(uv[a].lerp(uv[b], t))
	if not uv2.is_empty():
		uv2.append(uv2[a].lerp(uv2[b], t))
	made[key] = i
	return i


# Closes the openings of every cut part: all cut edges around a part, from every part it touches,
# are chained into loops (an opening where three parts meet, like the hips and two legs, is made
# of pieces of two planes), and each closed loop is filled with a fan from its centre, facing out
# of the part.
func _emit_caps(caps: Dictionary, rigs: Dictionary) -> void:
	var by_part := {}  # "rig id:part" -> [rig, part, segments]
	for pair in caps:
		var cap: Array = caps[pair]
		var rig: Dictionary = cap[4]
		for part in [cap[0], cap[1]]:
			var k := "%d:%d" % [rig["id"], part]
			if not by_part.has(k):
				by_part[k] = [rig, part, []]
			(by_part[k][2] as Array).append_array(cap[3])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = CAP_COLOR
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for k in by_part:
		var rig: Dictionary = by_part[k][0]
		var part: int = by_part[k][1]
		var pi := _cut_part(rig, part)
		var inside: Vector3 = (
			(part_box[pi] as AABB).get_center() if part_box[pi] != null else Vector3.ZERO
		)
		var p := PackedVector3Array()
		var nn := PackedVector3Array()
		# Gaps up to a tenth of the part's size are closed.
		var tol := 0.1 * ((part_box[pi] as AABB).size.length() if part_box[pi] != null else 0.0)
		for loop in _loops(by_part[k][2], tol):
			var c := Vector3.ZERO
			for x in loop:
				c += x
			c /= float(loop.size())
			# Newell normal of the loop, turned to face out of the part.
			var face := Vector3.ZERO
			for i in loop.size():
				var a: Vector3 = loop[i]
				var b: Vector3 = loop[(i + 1) % loop.size()]
				face += Vector3(
					(a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)
				)
			face = face.normalized()
			if face.dot(c - inside) < 0.0:
				face = -face
			for i in loop.size():
				p.append(c)
				p.append(loop[i])
				p.append(loop[(i + 1) % loop.size()])
				for j in 3:
					nn.append(face)
		if p.is_empty():
			continue
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = p
		arr[Mesh.ARRAY_NORMAL] = nn
		_add(pi, Mesh.PRIMITIVE_TRIANGLES, arr, mat, Transform3D.IDENTITY, "Cap")


# Chains cut edges [key a, key b, point a, point b] into closed loops of points. Where three parts
# meet, one triangle touching all three is kept whole, which leaves a short gap in the chain:
# open chains are joined end to end across gaps shorter than `tol`. A chain that still does not
# close is left open rather than filled with a fan that would cover more than the cut.
func _loops(segs: Array, tol: float) -> Array:
	var next := {}
	var at := {}
	for sgm in segs:
		next[sgm[0]] = (next.get(sgm[0], []) as Array) + [sgm[1]]
		next[sgm[1]] = (next.get(sgm[1], []) as Array) + [sgm[0]]
		at[sgm[0]] = sgm[2]
		at[sgm[1]] = sgm[3]
	var used := {}
	var closed: Array = []
	var open: Array = []
	for start in next:
		if used.has(start) or (next[start] as Array).size() != 1:
			continue
		open.append(_walk(start, next, at, used))
	for start in next:
		if used.has(start):
			continue
		var pts := _walk(start, next, at, used)
		if pts.size() >= 3:
			closed.append(pts)
	# Join open chains: repeatedly attach the chain whose end is nearest this chain's end.
	while not open.is_empty():
		var chain: Array = open.pop_back()
		while true:
			var best := -1
			var best_d := tol
			var flip := false
			for j in open.size():
				var o: Array = open[j]
				var d0 := (chain[chain.size() - 1] as Vector3).distance_to(o[0])
				var d1 := (chain[chain.size() - 1] as Vector3).distance_to(o[o.size() - 1])
				if d0 < best_d:
					best_d = d0
					best = j
					flip = false
				if d1 < best_d:
					best_d = d1
					best = j
					flip = true
			if best < 0:
				break
			var o: Array = open.pop_at(best)
			if flip:
				o.reverse()
			chain.append_array(o)
		if chain.size() >= 3 and (chain[0] as Vector3).distance_to(chain[chain.size() - 1]) < tol:
			closed.append(chain)
	return closed


func _walk(start, next: Dictionary, at: Dictionary, used: Dictionary) -> Array:
	var pts: Array = [at[start]]
	used[start] = true
	var cur = start
	while true:
		var step = null
		for k in next[cur]:
			if not used.has(k):
				step = k
				break
		if step == null:
			break
		used[step] = true
		pts.append(at[step])
		cur = step
	return pts


# The piece for a key, made on first use; a cut part also has its depth, limb axis and joint.
func _part(key: String, depth := 0, axis = null, joint = null) -> int:
	if part_of.has(key):
		return part_of[key]
	part_depth.append(depth)
	part_axis.append(axis)
	part_joint.append(joint)
	var holder := Node3D.new()
	holder.name = "Piece%d" % pieces.size()
	root.add_child(holder)
	part_of[key] = pieces.size()
	pieces.append(holder)
	part_box.append(null)
	return part_of[key]


# One static mesh copy into piece `pi`, at world transform `xform`.
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


func _surface_aabb(arrays: Array) -> AABB:
	var bl := _blocks(arrays[Mesh.ARRAY_VERTEX])
	var lo: Vector3 = (bl[0] as PackedVector3Array)[0]
	var hi: Vector3 = lo
	for blk in bl:
		for p in blk as PackedVector3Array:
			lo = lo.min(p)
			hi = hi.max(p)
	return AABB(lo, hi - lo)


func _blocks(arr) -> Array:
	var out := []
	var n: int = arr.size()
	var i := 0
	while i < n:
		out.append(arr.slice(i, mini(i + BLOCK, n)))
		i += BLOCK
	return out


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


# Placement (Explode.layout in lean/Explode.lean): whole shells and the root part first, then cut
# parts by depth, each group nearest the model centre first (larger first on ties); each moves out along its direction by the smallest candidate amount at
# which its box is `gap` away, on some axis, from every box placed before it. Placed pieces never
# move again, so every pair is checked once, when the later one is placed.
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
	var a2: Array = []
	var j2: Array = []
	for k in keys:
		var i: int = k[3]
		c2.append(centres[i])
		h2.append(halves[i])
		p2.append(pieces[i])
		a2.append(part_axis[i])
		j2.append(part_joint[i])
	centres = c2
	halves = h2
	pieces = p2
	dirs.clear()
	moves.clear()
	var placed: Array = []
	for i in n:
		# A cut part moves along its limb, tilted away from the body's centre line so paired limbs
		# spread apart; a whole shell moves out from the model centre.
		var off: Vector3 = (centres[i] as Vector3) - centre
		if a2[i] != null:
			off = (a2[i] as Vector3).normalized()
			var lat: Vector3 = (j2[i] as Vector3) - centre
			lat -= off * lat.dot(off)
			if lat.length() > 0.02 * radius:
				off += lat.normalized() * 0.5
		var v: Vector3 = (
			off.normalized() * radius
			if off.length() > 1e-6 * radius
			else _spread_dir(i, n) * radius
		)
		dirs.append(v)
		var t := _place(centres[i], halves[i], v, placed)
		moves.append(t)
		placed.append((centres[i] as Vector3) + v * t)


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
