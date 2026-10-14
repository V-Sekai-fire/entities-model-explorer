extends RefCounted
# Exploded view where no two pieces intersect.
#
# Pieces (lawnjelly's godot-splerger, one way only): every MeshInstance3D under the model roots
# is split by surface (split_by_surface), then every surface by ONE world-space grid over the
# whole model (split): each triangle goes to the cell of its centroid, no face is cut. Copies are
# static, taken at the current pose, so they do not move while exploded (the guarantee needs
# static pieces).
#
# Layout: piece i has a world-space box (centre c_i, half extents h_i) and a direction v_i out
# from the model centre. Pieces are placed nearest the centre first; each moves along v_i by the
# smallest amount at which its box is at least `gap` away, on some axis, from every box placed
# before it (so the core stays put and outer parts move only as far as they must).
# lean/Explode.lean defines the same placement over exact rationals and proves (layout_sound,
# separated_disjoint) that no two boxes of a layout share a point, so no two meshes intersect.
# `lake exe explode_check` re-checks a layout printed by `print_layout()` in exact arithmetic.
#
# The guarantee is for the resting layout; during the short move-out animation pieces may pass
# through each other.

const WIRE_GROUP := "vsk_web_wire"
const GAP := 0.03     # minimum distance between boxes, as a share of the model radius
const MOVE_TIME := 0.35
# Placement works with a gap slightly above GAP: candidates aim at AIM x gap, a spot counts as
# free at KEEP x gap; float32 rounding (about 1e-7 of the model size) stays far below the margin.
const AIM := 1.002
const KEEP := 1.001

var root: Node3D             # holds the piece copies while exploded
var hidden: Array = []       # nodes this script hid, restored by implode()
var centres: Array = []      # world box centres (Vector3)
var halves: Array = []       # world box half extents (Vector3)
var dirs: Array = []         # directions (Vector3)
var pieces: Array = []       # MeshInstance3D copies
var moves: Array = []       # how far each piece moves along its direction (float)
var gap := 0.0


# Builds the pieces and moves them out. `models` are the loaded model roots; `parent` receives the
# piece root (it must not be inside a model, so the model's own animation does not move pieces).
func explode(models: Array, parent: Node, animate := true) -> void:
	implode()
	root = Node3D.new()
	root.name = "ExplodedPieces"
	parent.add_child(root)
	var surfs: Array = []  # [arrays, prim, material, world xform, name]
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
	# One world-space grid over the whole model (splerger's split): every triangle goes to the
	# cell of its centroid, per surface, so a piece is (material, cell). No face is cut.
	var box := AABB()
	var first := true
	for e in surfs:
		var sb: AABB = (e[3] as Transform3D) * _surface_aabb(e[0])
		box = sb if first else box.merge(sb)
		first = false
	var cell := maxf(maxf(box.size.x, box.size.y), box.size.z) / float(CELLS)
	var counts := Vector3i(clampi(ceili(box.size.x / cell - 1e-6), 1, CELLS), clampi(ceili(box.size.y / cell - 1e-6), 1, CELLS), clampi(ceili(box.size.z / cell - 1e-6), 1, CELLS))
	for e in surfs:
		var parts: Array = [e[0]]
		if int(e[1]) == Mesh.PRIMITIVE_TRIANGLES and cell > 0.0:
			parts = _split_grid(e[0], e[3], box.position, cell, counts)
		for k in parts.size():
			_emit(e[1], parts[k], e[2], e[3], "%s_%d" % [e[4], k])
	if pieces.is_empty():
		return
	_layout()
	for i in pieces.size():
		var p: MeshInstance3D = pieces[i]
		var target: Vector3 = p.global_position + (dirs[i] as Vector3) * float(moves[i])
		if animate:
			p.create_tween().tween_property(p, "global_position", target, MOVE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
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


func is_exploded() -> bool:
	return root != null


func _ancestors_visible(n: Node, stop: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != stop.get_parent():
		if p is Node3D and not (p as Node3D).visible:
			return false
		p = p.get_parent()
	return true


# Static copies of `mi`'s surfaces at the current pose (splerger's split_by_surface): skinned
# meshes through bake_mesh_from_current_skeleton_pose(), blend-shaped ones through
# bake_mesh_from_current_blend_shape_mix().
func _collect(mi: MeshInstance3D, surfs: Array) -> void:
	var src: Mesh = mi.mesh
	if mi.skin != null and mi.get_node_or_null(mi.skeleton) is Skeleton3D:
		src = mi.bake_mesh_from_current_skeleton_pose()
	elif src.get_blend_shape_count() > 0:
		src = mi.bake_mesh_from_current_blend_shape_mix()
	if src == null:
		return
	for s in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		# Static copy: no skinning data, no custom shader channels.
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		for c in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			arrays[c] = null
		surfs.append([arrays, src.surface_get_primitive_type(s), mi.get_active_material(s), mi.global_transform, "%s_%d" % [mi.name, s]])


func _surface_aabb(arrays: Array) -> AABB:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bl := _blocks(pos)
	var lo: Vector3 = (bl[0] as PackedVector3Array)[0]
	var hi: Vector3 = lo
	for blk in bl:
		for p in (blk as PackedVector3Array):
			lo = lo.min(p)
			hi = hi.max(p)
	return AABB(lo, hi - lo)


# One static piece from surface arrays, at world transform `xform`.
func _emit(prim: int, arrays: Array, mat: Material, xform: Transform3D, piece_name: String) -> void:
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(prim, arrays)
	if am.get_surface_count() == 0:
		return
	if mat != null:
		am.surface_set_material(0, mat)
	var p := MeshInstance3D.new()
	p.name = piece_name
	p.mesh = am
	root.add_child(p)
	p.global_transform = xform
	var box: AABB = xform * am.get_aabb()
	centres.append(box.get_center())
	halves.append(box.size * 0.5)
	pieces.append(p)


# --- Grid split ----------------------------------------------------------------------------
# Compiled guest loops copy the packed arrays they index into guest memory, and the host refuses a
# window over 4096 elements, so large arrays are read through blocks of at most BLOCK elements
# (`_blocks`, read as blocks[i / BLOCK][i % BLOCK]) and built with append only.

const CELLS := 3     # grid cells along the model's longest side
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
func _split_grid(arrays: Array, xform: Transform3D, origin: Vector3, cell: float, counts: Vector3i) -> Array:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		idx = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		for i in pos.size():
			idx.append(i)
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
			var key := Vector3i(clampi(int(floor(g.x)), 0, counts.x - 1), clampi(int(floor(g.y)), 0, counts.y - 1), clampi(int(floor(g.z)), 0, counts.z - 1))
			if not cell_of.has(key):
				cell_of[key] = cell_of.size()
			tri_group.append(cell_of[key])
			t += 3
	if cell_of.size() < 2:
		return [arrays]
	return _gather(arrays, pos_b, idx_b, tri_group, cell_of.size())


# Builds one surface per group from the triangles whose tri_group entry names it, copying every
# per-vertex array the surface has and renumbering the vertices it uses.
func _gather(arrays: Array, pos_b: Array, idx_b: Array, tri_group: PackedInt32Array, ng: int) -> Array:
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


# Placement (Explode.layout in lean/Explode.lean): pieces sorted nearest the model centre first
# (larger first on ties); each moves out along its direction by the smallest candidate amount at
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
	# Order: distance from the centre, then larger box first.
	var keys: Array = []
	for i in n:
		var d: float = ((centres[i] as Vector3) - centre).length()
		var vol: float = (halves[i] as Vector3).x * (halves[i] as Vector3).y * (halves[i] as Vector3).z
		keys.append([d, -vol, i])
	keys.sort()
	var c2: Array = []
	var h2: Array = []
	var p2: Array = []
	for k in keys:
		var i: int = k[2]
		c2.append(centres[i])
		h2.append(halves[i])
		p2.append(pieces[i])
	centres = c2
	halves = h2
	pieces = p2
	dirs.clear()
	moves.clear()
	var placed: Array = []
	for i in n:
		var off: Vector3 = (centres[i] as Vector3) - centre
		var v: Vector3 = off.normalized() * radius if off.length() > 1e-6 * radius else _spread_dir(i, n) * radius
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
		print("EXPLODE piece %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f %.17f" % [c.x, c.y, c.z, h.x, h.y, h.z, v.x, v.y, v.z, moves[i]])
	print("EXPLODE end %d" % centres.size())
