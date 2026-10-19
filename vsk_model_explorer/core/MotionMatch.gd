extends Node
# M walks the open rigged model like a character controller. Keyboard: W A S D move (relative to
# the camera), Shift runs, C crouches, Z crawls (each again to stand), Space jumps, M stops.
# Gamepad: left stick moves, right stick turns the camera, A jumps, B crouches, Y crawls, the right
# trigger runs, Start stops. Motion matching picks the motion: mm.elf
# (interactor-motion-matching-guest, a port of godot-motion-matching) holds a pose database built
# from Kimodo clips and the O3DE MotionMatching gem's clips (SOMA skeleton, res://motion/mm/),
# predicts where the input takes the character, and every 0.1 s picks the clip frame whose next
# second fits best, among poses of the asked kind (standing, crouching or crawling; a jump picks a
# take-off and plays through to the landing). The same clips are moved onto the model's rig once
# by skintokens.elf ("whole": every frame, root travel kept) and played here.
# Test mode: `-- <rigged.glb> --move-quit` opens the moves, walks forward, turns and runs,
# checks how far and which way the model went, then quits with 0, or 1 on any failure.

signal moves_made(path: String)

const Motion = preload("res://vsk_model_explorer/core/Motion.gd")
const Bintr = preload("res://vsk_model_explorer/core/Bintr.gd")
const MM_ELF := "res://mm.elf"
const RIG_ELF := "res://skintokens.elf"
const DIR := "res://motion/mm"
const PREFIX := "mm_"
const BLEND := 0.2
const STAND := 0
const CROUCH := 1
const CRAWL := 2
const MODE_NAMES := ["standing", "crouching", "crawling"]
# The controls card rows this adds; the status line repeats them while walking.
# Keyboard and gamepad on one row each.
const CARD_ROWS := [
	["keys", ["M"], "M or Start", "Walk mode"],
	["keys", ["W"], "WASD or stick", "Walk"],
	["keys", ["Shift"], "Shift or RT", "Run"],
	["keys", ["C"], "C or pad B", "Crouch"],
	["keys", ["Z"], "Z or pad Y", "Crawl"],
	["keys", ["Space"], "Space or A", "Jump"],
]
const HELP := "W A S D walk, Shift run, C crouch, Z crawl, Space jump, M stop (gamepad: stick, RT, B, Y, A, Start)"

var source := ""
var busy := false
var on := false
var status := Callable()
var _helper: Node
var _mm: Node
var _scene: Node3D
var _player: AnimationPlayer
var _skeleton: Skeleton3D
var _keys: PackedStringArray = []
var _hips_track := -1
var _hips_path := ""
var _scale := 1.0
var _phi := 0.0
var _walk_speed := 1.3
var _run_speed := 3.5
var _mode_speed := [1.3, 0.8, 0.4]
var _mode := STAND
var _jump_pressed := false
var _pad_prev := {}
var _origin := Vector3.ZERO
var _clip := -1
var _last_world := Vector3.ZERO
var _test := false
var _test_opened := false
var _test_input := Vector2.ZERO
var _test_run := false
var _test_mode := STAND
var _test_jump := false
var _start_after_load := false
var _jumping := false
var _kind := 0


func _ready() -> void:
	_test = "--move-quit" in OS.get_cmdline_user_args()
	get_parent().gltf_is_loaded.connect(_on_loaded)
	_helper = Motion.new()
	_helper.status = func(t): say(t)
	add_child(_helper)


func available() -> bool:
	return FileAccess.file_exists(MM_ELF) and FileAccess.file_exists(DIR.path_join("clips.tsv"))


func say(text: String) -> void:
	if status.is_valid():
		status.call(text)
	if _test and text.begins_with("Move failed"):
		printerr("MOVE-FAIL ", text)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if not k or not k.pressed or k.echo:
		return
	if k.keycode == KEY_M:
		toggle()
	elif on and k.keycode == KEY_C:
		_mode = STAND if _mode == CROUCH else CROUCH
	elif on and k.keycode == KEY_Z:
		_mode = STAND if _mode == CRAWL else CRAWL
	elif on and k.keycode == KEY_SPACE:
		_jump_pressed = true


func toggle() -> void:
	if on:
		stop()
	else:
		start()


# Gamepad buttons on the frame they go down.
func _pad_down(button: JoyButton) -> bool:
	var now := Input.is_joy_button_pressed(0, button)
	var was: bool = _pad_prev.get(button, false)
	_pad_prev[button] = now
	return now and not was


func _pad() -> void:
	if _pad_down(JOY_BUTTON_START):
		toggle()
	if not on:
		return
	if _pad_down(JOY_BUTTON_A):
		_jump_pressed = true
	if _pad_down(JOY_BUTTON_B):
		_mode = STAND if _mode == CROUCH else CROUCH
	if _pad_down(JOY_BUTTON_Y):
		_mode = STAND if _mode == CRAWL else CRAWL


func _on_loaded(ok: bool, scene: Node) -> void:
	stop()
	_scene = scene as Node3D if ok else null
	if _test and not ok:
		printerr("MOVE-FAIL the model did not open")
		get_tree().quit(1)
		return
	if _start_after_load and ok:
		# The moves file just opened.
		_start_after_load = false
		if _test:
			_run_test.call_deferred()
		else:
			start.call_deferred()
	elif _test and not _test_opened:
		_test_opened = true
		if _has_moves():
			_run_test.call_deferred()
		else:
			start.call_deferred()


# 1. The moves file: every database clip on this rig. 2. The database in mm.elf.
func start() -> void:
	if busy or _scene == null:
		return
	if not available():
		return say("Move needs mm.elf and the clips in res://motion/mm.")
	if not _has_moves():
		if source == "" or source.get_extension().to_lower() != "glb":
			return say("Move needs an open .glb file with a rig.")
		busy = true
		var out := await _make_moves()
		busy = false
		if out != "":
			_start_after_load = true
			moves_made.emit(out)
		elif _test:
			get_tree().quit(1)
		return
	if not _bake():
		return
	_begin()


func stop() -> void:
	if not on:
		return
	on = false
	remove_from_group("walk_mode")
	if _player:
		_player.stop()
	if _scene:
		_scene.transform = Transform3D.IDENTITY
	say("")


func _has_moves() -> bool:
	_player = null
	for p in _scene.find_children("*", "AnimationPlayer", true, false):
		if (p as AnimationPlayer).has_animation(PREFIX + "walk"):
			_player = p
	return _player != null


static func clip_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for line in FileAccess.get_file_as_string(DIR.path_join("clips.tsv")).split("\n", false):
		out.append(line.split("\t")[0])
	return out


static func _soma() -> Dictionary:
	var names := FileAccess.get_file_as_string(DIR.path_join("skeleton.txt")).strip_edges()
	var parents := PackedInt32Array()
	for p in FileAccess.get_file_as_string(DIR.path_join("parents.txt")).split("\n", false):
		parents.append(int(p))
	return {names = names, parents = parents}


func _make_moves() -> String:
	var t0 := Time.get_ticks_msec()
	var keys := clip_keys()
	var soma := _soma()
	var dir := OS.get_user_data_dir().path_join("moves")
	DirAccess.make_dir_recursive_absolute(dir)
	var cur := source
	var out := dir.path_join(source.get_file().get_basename() + ".moves.glb")
	for i in keys.size():
		var label := "Move: putting %s on the rig (%d of %d)" % [keys[i], i + 1, keys.size()]
		say(label)
		var rig: Node = _helper._sandbox(RIG_ELF, "skintokens_motion_start")
		if rig == null:
			return _fail("skintokens.elf has no motion step")
		var xf := FileAccess.get_file_as_bytes(DIR.path_join(keys[i] + ".f32")).to_float32_array()
		var started := str(
			rig.vmcall(
				"skintokens_motion_start",
				cur,
				PREFIX + keys[i],
				"whole",
				soma.names,
				soma.parents,
				xf,
				30.0
			)
		)
		if not started.begins_with("STARTED"):
			_helper._free(rig)
			return _fail(started)
		if not await _helper._drive(rig, "skintokens_pump", label, t0):
			return ""
		var glb := PackedByteArray()
		var size := int(rig.vmcall("skintokens_result_size"))
		while glb.size() < size:
			var chunk: PackedByteArray = rig.vmcall(
				"skintokens_result_chunk", glb.size(), min(size - glb.size(), 8 << 20)
			)
			if chunk.is_empty():
				_helper._free(rig)
				return _fail("the result did not read back")
			glb.append_array(chunk)
		_helper._free(rig)
		_helper._close_files()
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f == null:
			return _fail("cannot save %s" % out)
		f.store_buffer(glb)
		f.close()
		cur = out
	print("MOVE-MADE %s clips=%d ms=%d" % [out, keys.size(), Time.get_ticks_msec() - t0])
	say("")
	return out


func _fail(why: String) -> String:
	busy = false
	say("Move failed: " + why)
	return ""


func _bake() -> bool:
	if _mm == null:
		_mm = Bintr.make(self, MM_ELF, 512, 4096)
		if not _mm.has_function("mm_step"):
			_fail("mm.elf did not load")
			return false
	_mm.vmcall("mm_clear")
	_keys = clip_keys()
	var soma := _soma()
	for k in _keys:
		var xf := FileAccess.get_file_as_bytes(DIR.path_join(k + ".f32")).to_float32_array()
		var r := str(_mm.vmcall("mm_add_clip", k, soma.names, soma.parents, xf, 30.0))
		if not r.begins_with("ADDED"):
			_fail(r)
			return false
	var baked := str(_mm.vmcall("mm_bake"))
	print("MOVE-BAKE ", baked)
	if not baked.begins_with("BAKED"):
		_fail(baked)
		return false
	# Walk at the walk clip's usual speed; run at the usual top speed of the running clips.
	var tops := []
	for line in str(_mm.vmcall("mm_clips")).split("\n", false):
		var w := line.split(" ")
		if w.size() < 8:
			continue
		if w[0] == "walk":
			_walk_speed = float(w[6])
		elif "run" in w[0] or "jog" in w[0] or "sprint" in w[0]:
			tops.append(float(w[7]))
	if not tops.is_empty():
		tops.sort()
		_run_speed = tops[tops.size() / 2]
	_mode_speed = [_walk_speed, 0.0, 0.0]
	var modes := str(_mm.vmcall("mm_modes"))
	for line in modes.split("\n", false):
		var w := line.split(" ")
		if w[0] == "crouch":
			_mode_speed[CROUCH] = float(w[2])
		elif w[0] == "crawl":
			_mode_speed[CRAWL] = float(w[2])
	print(
		(
			"MOVE-SPEEDS walk=%.2f run=%.2f crouch=%.2f crawl=%.2f m/s | %s"
			% [
				_walk_speed,
				_run_speed,
				_mode_speed[CROUCH],
				_mode_speed[CRAWL],
				modes.replace("\n", "; ")
			]
		)
	)
	return _calibrate()


# The rig's clips are the database clips moved onto the rig: the root travels the same path,
# scaled by the rig's height and turned to the rig's forward. Measure both from the walk.
func _calibrate() -> bool:
	_skeleton = null
	var walk := _player.get_animation(PREFIX + "walk")
	var best := 0.0
	for t in walk.get_track_count():
		if walk.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		var a := walk.position_track_interpolate(t, 0.0)
		var b := walk.position_track_interpolate(t, walk.length)
		var d := Vector2(b.x - a.x, b.z - a.z).length()
		if d > best:
			best = d
			_hips_track = t
	if _hips_track < 0:
		_fail("the walk clip has no root travel")
		return false
	_hips_path = str(walk.track_get_path(_hips_track))
	var node := _player.get_node(_player.root_node).get_node_or_null(
		NodePath(_hips_path.get_slice(":", 0))
	)
	_skeleton = node as Skeleton3D
	var rig_d := _root_model(walk, walk.length) - _root_model(walk, 0.0)
	var soma := _mm_root("walk")
	if soma.length() < 1e-3 or Vector2(rig_d.x, rig_d.z).length() < 1e-6:
		_fail("the walk clip does not travel")
		return false
	_scale = Vector2(rig_d.x, rig_d.z).length() / Vector2(soma.x, soma.z).length()
	_phi = atan2(rig_d.x, rig_d.z) - atan2(soma.x, soma.z)
	print(
		"MOVE-CALIBRATE scale=%.4f turn=%.1f deg hips=%s" % [_scale, rad_to_deg(_phi), _hips_path]
	)
	return true


# The SOMA root travel of a clip, first frame to last, from mm.elf's clip table.
func _mm_root(key: String) -> Vector3:
	var lines := str(_mm.vmcall("mm_clips")).split("\n", false)
	for line in lines:
		var w := line.split(" ")
		if w[0] == key and w.size() >= 6:
			return Vector3(float(w[4]), 0, float(w[5]))
	return Vector3.ZERO


# Where the clip's hips are on the floor at time t, in the model's space.
func _root_model(anim: Animation, t: float) -> Vector3:
	var local := anim.position_track_interpolate(_hips_track, t)
	var p := local
	if _skeleton:
		var bone := _skeleton.find_bone(_hips_path.get_slice(":", 1))
		var parent := _skeleton.get_bone_parent(bone) if bone >= 0 else -1
		if parent >= 0:
			p = _skeleton.get_bone_global_rest(parent) * local
		p = _to_scene(_skeleton) * p
	return Vector3(p.x, 0, p.z)


func _to_scene(n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur and cur != _scene:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


func _begin() -> void:
	_mm.vmcall("mm_reset", 0.0, 0.0, 0.0, max(0, _keys.find("idle")))
	_clip = -1
	_mode = STAND
	_jump_pressed = false
	_origin = _scene.position
	on = true
	add_to_group("walk_mode")
	_last_world = _origin
	say(HELP)


func _input_dir() -> Vector2:
	if _test:
		return _test_input
	var v := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X), -Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	)
	if v.length() < 0.2:
		v = Vector2.ZERO
	elif v.length() > 1.0:
		v = v.normalized()
	if Input.is_key_pressed(KEY_W):
		v.y += 1
	if Input.is_key_pressed(KEY_S):
		v.y -= 1
	if Input.is_key_pressed(KEY_A):
		v.x -= 1
	if Input.is_key_pressed(KEY_D):
		v.x += 1
	return v.normalized() if v.length() > 1.0 else v


func _process(delta: float) -> void:
	if not _test:
		_pad()
	if not on or _mm == null:
		return
	var dt: float = clamp(delta, 1.0 / 240.0, 1.0 / 20.0)
	var input := _input_dir()
	var running := (
		_test_run
		if _test
		else (
			Input.is_key_pressed(KEY_SHIFT) or Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.5
		)
	)
	if _test:
		_mode = _test_mode
		_jump_pressed = _jump_pressed or _test_jump
		_test_jump = false
	# The right stick turns the camera.
	var cc0 := get_parent().get_node_or_null("CamController") as Node3D
	var rx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	if cc0 and abs(rx) > 0.2 and not _test:
		cc0.rotate_y(-rx * 2.0 * dt)
	# Clip speeds are SOMA metres a second; the scene is the rig's size. Only standing runs.
	var base: float = (
		_mode_speed[_mode] if _mode != STAND else (_run_speed if running else _walk_speed)
	)
	var speed := base * _scale * input.length()
	# Camera-relative input in the scene: forward is away from the camera, on the floor.
	var cam := get_viewport().get_camera_3d()
	var fwd := Vector3(0, 0, -1)
	var right := Vector3(1, 0, 0)
	if cam and not _test:
		fwd = -cam.global_transform.basis.z
		fwd.y = 0
		fwd = fwd.normalized() if fwd.length() > 1e-4 else Vector3(0, 0, -1)
		right = Vector3(-fwd.z, 0, fwd.x)
	var want := (
		(fwd * input.y + right * input.x).normalized() * speed if speed > 0 else Vector3.ZERO
	)
	# Scene to SOMA: undo the rig's turn and scale.
	var soma_v := want.rotated(Vector3.UP, -_phi) / _scale
	var jump := 1 if _jump_pressed else 0
	_jump_pressed = false
	var r: PackedFloat32Array = _mm.vmcall("mm_step", dt, soma_v.x, soma_v.z, NAN, _mode, jump)
	if r.size() < 15:
		return
	_jumping = r[14] > 0.5
	_kind = int(r[13])
	var clip := int(r[0])
	var t := float(r[1])
	var name := PREFIX + _keys[clip]
	if clip != _clip or r[8] > 0.5:
		_player.play(name, BLEND if _clip >= 0 else 0.0)
		_player.seek(t, true)
		_clip = clip
	elif abs(_player.current_animation_position - t) > 0.05:
		_player.seek(t, true)
	# Place the model so the clip's root at t lands on the character.
	var anim := _player.get_animation(name)
	var root_m := _root_model(anim, t)
	var turn: float = float(r[4]) - float(r[7])
	var char_scene := Vector3(r[2], 0, r[3]).rotated(Vector3.UP, _phi) * _scale + _origin
	var basis := Basis(Vector3.UP, turn)
	_scene.transform = Transform3D(basis, char_scene - basis * root_m)
	# The camera follows.
	var cc := get_parent().get_node_or_null("CamController") as Node3D
	if cc:
		cc.position += char_scene - _last_world
	_last_world = char_scene
	var label := "Walk mode, %s%s: %s" % [MODE_NAMES[_mode], ", jumping" if _jumping else "", HELP]
	if status.is_valid():
		status.call(label)


func _run_test() -> void:
	if not _has_moves():
		printerr("MOVE-FAIL the opened file has no moves")
		get_tree().quit(1)
		return
	if not _bake():
		get_tree().quit(1)
		return
	_begin()
	var shots := OS.get_environment("MOVE_SHOT")
	var cc := get_parent().get_node_or_null("CamController") as Node3D
	if shots != "" and cc:
		# Step back so the whole model is in the pictures.
		cc.scale *= 2.0
	# [name, input, run, seconds, heading in degrees (0 = away from the camera, 90 = right)]
	# [name, input, run, seconds, heading in degrees (0 = away from the camera, 90 = right),
	#  mode, jump]
	var plan := [
		["idle", Vector2.ZERO, false, 2.0, 0.0, STAND, false],
		["walk", Vector2(0, 1), false, 5.0, 0.0, STAND, false],
		["turn", Vector2(1, 0), false, 4.0, 90.0, STAND, false],
		["run", Vector2(1, 0), true, 4.0, 90.0, STAND, false],
		["jump", Vector2(1, 0), false, 3.0, 90.0, STAND, true],
		["crouch", Vector2(0, 1), false, 5.0, 0.0, CROUCH, false],
		["crawl", Vector2(0, 1), false, 6.0, 0.0, CRAWL, false],
		["stand", Vector2.ZERO, false, 3.0, 0.0, STAND, false],
	]
	var ok := true
	for step in plan:
		_test_input = step[1]
		_test_run = step[2]
		_test_mode = step[5]
		_test_jump = step[6]
		if step[5] != STAND and _mode_speed[step[5]] <= 0.0:
			print("MOVE-STEP %s SKIP no poses of that kind" % step[0])
			continue
		var seen := {}
		var t := 0.0
		var kind_ok := 0.0
		var kind_all := 0.0
		var air := 0.0
		var jumped := false
		# Judge the second half of each step: the first half is the change of direction.
		var p0 := _last_world
		while t < step[3]:
			await get_tree().process_frame
			var dt := get_process_delta_time()
			t += dt
			seen[_keys[_clip]] = true
			jumped = jumped or _jumping
			if _kind == 4:
				air += dt
			if t < step[3] * 0.5:
				p0 = _last_world
			else:
				kind_all += dt
				kind_ok += dt if _kind == step[5] else 0.0
		var moved: Vector3 = _last_world - p0
		var secs: float = step[3] * 0.5
		var speed: float = Vector2(moved.x, moved.z).length() / secs
		var want: float = 0.0
		if step[1] != Vector2.ZERO:
			var base: float = _mode_speed[step[5]]
			if step[5] == STAND:
				base = _run_speed if step[2] else _walk_speed
			want = base * _scale
		var heading: float = rad_to_deg(atan2(moved.x, -moved.z))
		var off: float = abs(wrapf(heading - step[4], -180.0, 180.0))
		var share: float = kind_ok / kind_all if kind_all > 0.0 else 0.0
		var good: bool = (
			speed < 0.2 * _scale if want == 0.0 else (speed > 0.6 * want and off < 25.0)
		)
		if step[6]:
			good = jumped and air > 0.1
		elif step[5] != STAND:
			good = good and share >= 0.7
		print(
			(
				"MOVE-STEP %s speed=%.2f want=%.2f heading=%.0f kind_share=%.2f air=%.2f clips=%s %s"
				% [
					step[0],
					speed,
					want,
					heading,
					share,
					air,
					",".join(seen.keys()),
					"ok" if good else "BAD"
				]
			)
		)
		if shots != "":
			get_viewport().get_texture().get_image().save_png(shots + "-%s.png" % step[0])
		ok = ok and good
	print("MOVE-OK" if ok else "MOVE-FAIL")
	get_tree().quit(0 if ok else 1)
