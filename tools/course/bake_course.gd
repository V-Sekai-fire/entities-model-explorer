extends SceneTree
# Bake the walk-mode obstacle course with the SolidCraft CAD kernel (interactor-solidcraft-guest,
# run in godot-sandbox) and write it as glTF:
#
#   godot --headless --path <viewer project with godot-sandbox> --script tools/course/bake_course.gd \
#     -- <solidcraft-guest.elf> <out .glb>
#
# Every piece is one solid from the kernel's solid_mesh(kind, a, b, c): 0 box (length, width,
# height), 1 cylinder (radius, height), 2 sphere (radius), 3 torus (major, minor), all in mm.
# The course is laid out in metres for a 1.75 m person along -Z (away from the starting camera),
# one station after another, like a game level; the viewer scales it to the model.

const MM := 0.001
const KINDS := {"box": 0, "cylinder": 1, "sphere": 2, "torus": 3}

# Station colours: one per station so the stations read apart in a video.
const C_START := Color(0.30, 0.75, 0.40)
const C_STAIRS := Color(0.95, 0.65, 0.20)
const C_RAMP := Color(0.35, 0.60, 0.95)
const C_STONES := Color(0.85, 0.35, 0.65)
const C_BUMPS := Color(0.60, 0.45, 0.90)
const C_DUCK := Color(0.95, 0.40, 0.30)
const C_GAP := Color(0.25, 0.80, 0.80)
const C_FINISH := Color(1.00, 0.85, 0.20)
const C_POST := Color(0.85, 0.85, 0.85)

var sandbox
var course := Node3D.new()
var pieces := 0
var tris := 0
var stations: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("COURSE-FAIL usage: -- <solidcraft-guest.elf> <out.glb>")
		quit(2)
		return
	if not ClassDB.class_exists("Sandbox"):
		printerr("COURSE-FAIL godot-sandbox did not load")
		quit(1)
		return
	sandbox = ClassDB.instantiate("Sandbox")
	sandbox.set_memory_max(512)
	sandbox.load_buffer(FileAccess.get_file_as_bytes(args[0]))
	var r = sandbox.vmcall("solid_default")
	# Control: the kernel's canonical 10 x 20 x 30 mm box must come back with those bounds.
	if typeof(r) != TYPE_ARRAY or not r[0] or not is_equal_approx(float(r[9]) - float(r[6]), 30.0):
		printerr("COURSE-FAIL solid_default is not the 10 x 20 x 30 mm box: ", r)
		quit(1)
		return
	course.name = "ObstacleCourse"
	_build()
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(course, state) != OK or doc.write_to_filesystem(state, args[1]) != OK:
		printerr("COURSE-FAIL could not write ", args[1])
		quit(1)
		return
	var f := FileAccess.open(args[1].get_basename() + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"stations": stations, "pieces": pieces, "triangles": tris}, "\t"))
	f.close()
	print("COURSE-OK pieces=%d triangles=%d stations=%d out=%s" % [pieces, tris, stations.size(), args[1].get_file()])
	quit(0)


# The course, start to finish. z is where each station begins (metres, negative = ahead).
func _build() -> void:
	var z := 0.0
	# Start pad and gate posts.
	_station("start", z, "Start: walk ahead (away from the camera).")
	_piece("start-pad", "box", [2400, 2400, 20], Vector3(0, 0, z - 1.2), C_START)
	for x in [-1.3, 1.3]:
		_piece("start-post", "cylinder", [60, 1800, 0], Vector3(x, 0, z - 2.4), C_POST)
	z -= 4.0
	# Stairs: three lanes side by side, steps of 10, 17 and 25 cm, five up, a landing, five down.
	_station("stairs", z, "Stairs: lanes with 10, 17 and 25 cm steps.")
	var tread := 0.30
	for lane in [[-1.4, 0.10], [0.0, 0.17], [1.4, 0.25]]:
		var x: float = lane[0]
		var h: float = lane[1]
		for i in 5:
			_piece("step-up", "box", [1200, tread * 1000, h * 1000 * (i + 1)], Vector3(x, 0, z - tread * (i + 0.5)), C_STAIRS)
		_piece("landing", "box", [1200, 1500, h * 1000 * 5], Vector3(x, 0, z - tread * 5 - 0.75), C_STAIRS.darkened(0.15))
		for i in 5:
			_piece("step-down", "box", [1200, tread * 1000, h * 1000 * (5 - i)], Vector3(x, 0, z - tread * 5 - 1.5 - tread * (i + 0.5)), C_STAIRS)
	z -= tread * 10 + 1.5 + 2.0
	# Ramps: lanes at 10, 20 and 30 degrees up to a 1 m deck, then down the other side.
	_station("ramps", z, "Ramps: lanes at 10, 20 and 30 degrees, up to a 1 m deck.")
	var rise := 1.0
	var deck := 1.5
	var longest := rise / tan(deg_to_rad(10.0))
	for lane in [[-1.4, 10.0], [0.0, 20.0], [1.4, 30.0]]:
		var x: float = lane[0]
		var run := rise / tan(deg_to_rad(lane[1]))
		var start := z - (longest - run)
		_ramp(x, start, run, rise, false)
		_piece("deck", "box", [1200, deck * 1000, rise * 1000], Vector3(x, 0, start - run - deck * 0.5), C_RAMP.darkened(0.15))
		_ramp(x, start - run - deck, run, rise, true)
	z -= longest * 2 + deck + 2.0
	# Stepping stones: posts 35 cm high, 25 cm apart then 40 then 55, on a zigzag.
	_station("stones", z, "Stepping stones: 35 cm posts with growing gaps.")
	var sz := z
	var gaps := [0.25, 0.25, 0.40, 0.40, 0.55, 0.55]
	for i in gaps.size() + 1:
		_piece("stone", "cylinder", [250, 350, 0], Vector3(0.35 if i % 2 else -0.35, 0, sz - 0.25), C_STONES)
		if i < gaps.size():
			sz -= 0.5 + gaps[i]
	z = sz - 2.0
	# Bumps: half-buried spheres on a field.
	_station("bumps", z, "Bumps: uneven ground of half-buried spheres.")
	var rng := RandomNumberGenerator.new()
	rng.seed = 2327
	for i in 14:
		var r := rng.randf_range(0.25, 0.55)
		var p := Vector3(rng.randf_range(-1.6, 1.6), -r * 0.7, z - rng.randf_range(0.3, 3.7))
		_piece("bump", "sphere", [r * 1000, 0, 0], p, C_BUMPS)
	z -= 4.0 + 2.0
	# Duck under: a 1.3 m beam (crouch), then a 0.7 m tunnel roof (crawl).
	_station("duck", z, "Duck under: a 1.3 m beam to crouch under, then a 0.7 m roof to crawl under.")
	for x in [-1.3, 1.3]:
		_piece("beam-post", "box", [150, 150, 1300], Vector3(x, 0, z - 0.5), C_POST)
	_piece("crouch-beam", "box", [2750, 300, 200], Vector3(0, 1.3, z - 0.5), C_DUCK)
	for x in [-0.9, 0.9]:
		_piece("tunnel-wall", "box", [150, 2500, 700], Vector3(x, 0, z - 3.0), C_DUCK.darkened(0.2))
	_piece("tunnel-roof", "box", [1950, 2500, 120], Vector3(0, 0.7, z - 3.0), C_DUCK)
	z -= 4.25 + 2.0
	# Jump gap: two 40 cm platforms 80 cm apart.
	_station("gap", z, "Jump: two 40 cm platforms with an 80 cm gap.")
	_piece("gap-near", "box", [2400, 1500, 400], Vector3(0, 0, z - 0.75), C_GAP)
	_piece("gap-far", "box", [2400, 1500, 400], Vector3(0, 0, z - 1.5 - 0.8 - 0.75), C_GAP)
	z -= 3.8 + 2.0
	# Finish: a standing ring to run through and a pad.
	_station("finish", z, "Finish: run through the ring.")
	var ring := _piece("finish-ring", "torus", [1100, 90, 0], Vector3(0, 1.2, z - 0.2), C_FINISH)
	ring.rotation = Vector3(deg_to_rad(90.0), 0, 0)
	_piece("finish-pad", "box", [2400, 2400, 20], Vector3(0, 0, z - 1.5), C_FINISH.darkened(0.2))


# A ramp: a box sunk under the floor and tilted so its top runs from the floor at z0 up to
# `rise` after `run` metres (down = the mirror, high end first).
func _ramp(x: float, z0: float, run: float, rise: float, down: bool) -> void:
	var ln := sqrt(run * run + rise * rise)
	var th := 0.3
	var a := atan2(rise, run)
	var n := _piece("ramp-down" if down else "ramp-up", "box", [1200, ln * 1000, th * 1000], Vector3.ZERO, C_RAMP)
	# The piece sits on its bottom face centred at the origin; tilt it about its top centre.
	var top_mid := Vector3(x, rise * 0.5, z0 - run * 0.5)
	var tilt := Basis(Vector3.RIGHT, a if not down else -a)
	n.transform = Transform3D(tilt, top_mid - tilt * Vector3(0, th, 0))


func _station(name: String, z: float, text: String) -> void:
	stations.append({"name": name, "z": z, "text": text})


func _piece(name: String, kind: String, dims: Array, at: Vector3, colour: Color) -> MeshInstance3D:
	var r = sandbox.vmcall("solid_mesh", KINDS[kind], float(dims[0]), float(dims[1]), float(dims[2]))
	if typeof(r) != TYPE_ARRAY or r.size() != 5 or not r[0]:
		printerr("COURSE-FAIL solid_mesh(%s %s) failed" % [kind, str(dims)])
		quit(1)
		return MeshInstance3D.new()
	var pos: Array = r[2]
	var nrm: Array = r[3]
	var n := pos.size() / 3
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	verts.resize(n)
	normals.resize(n)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in n:
		# The kernel is Z-up; Godot is Y-up: (x, y, z) -> (x, z, -y) is a rotation.
		var v := Vector3(pos[i * 3], pos[i * 3 + 2], -pos[i * 3 + 1])
		verts[i] = v
		lo = lo.min(v)
		hi = hi.max(v)
		if nrm.size() == pos.size():
			normals[i] = Vector3(nrm[i * 3], nrm[i * 3 + 2], -nrm[i * 3 + 1])
	# Bottom centre at the origin, in metres.
	var shift := Vector3(-(lo.x + hi.x) * 0.5, -lo.y, -(lo.z + hi.z) * 0.5)
	if kind == "sphere" or kind == "torus":
		shift.y = -(lo.y + hi.y) * 0.5
	for i in n:
		verts[i] = (verts[i] + shift) * MM
	# The kernel winds front faces counter-clockwise (glTF); Godot takes clockwise as the front.
	var idx := PackedInt32Array(r[4])
	for t in range(0, idx.size() - 2, 3):
		var keep := idx[t + 1]
		idx[t + 1] = idx[t + 2]
		idx[t + 2] = keep
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.8
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "%s-%d" % [name, pieces]
	mi.mesh = mesh
	mi.position = at
	course.add_child(mi)
	mi.owner = course
	pieces += 1
	tris += int(r[1])
	return mi
