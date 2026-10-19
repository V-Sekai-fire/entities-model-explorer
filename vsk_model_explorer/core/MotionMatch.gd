extends Node
# M walks the open rigged model like a character controller. Keyboard: W A S D move (relative to
# the camera), Shift runs, C crouches, Z crawls (each again to stand), Space jumps, M stops.
# Mouse or touch: click or tap the floor and the model walks there; a double click or double tap
# runs there. A ring marks the point until the model arrives; any move key or the stick cancels it.
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
# Walk to a point: a press and release closer than TAP_SLOP pixels is a tap (a drag is not).
# The model stops within ARRIVE SOMA metres of the point.
const TAP_SLOP := 12.0
const ARRIVE := 0.3
# The controls card rows this adds; the status line repeats them while walking.
# Keyboard and gamepad on one row each.
const CARD_ROWS := [
	["keys", ["M"], "M or Start", "Walk mode"],
	["keys", ["W"], "WASD or stick", "Walk"],
	["mouse", "left", "Tap or click floor", "Walk there, 2x run"],
	["keys", ["Shift"], "Shift or RT", "Run"],
	["keys", ["C"], "C or pad B", "Crouch"],
	["keys", ["Z"], "Z or pad Y", "Crawl"],
	["keys", ["Space"], "Space or A", "Jump"],
]
const HELP := "W A S D or click the floor walk, double click runs there, Shift run, C crouch, Z crawl, Space jump, M stop (gamepad: stick, RT, B, Y, A, Start)"

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
var _target := Vector3.ZERO
var _has_target := false
var _target_run := false
var _press_pos := Vector2.ZERO
var _press_down := false
var _press_run := false
var _marker: MeshInstance3D
var _keys_testing := false
var _space_jumps := 0
var _trace := OS.get_environment("MOVE_TRACE") != ""


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


# The walk keys. In walk mode they belong to the walk: no other part of the viewer gets them.
const WALK_KEYS := [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SHIFT, KEY_C, KEY_Z, KEY_SPACE]


# _input runs before the GUI and before _unhandled_key_input, so a focused button or list does
# not take Space or a letter, and C does not also open the colour chart.
func _input(event: InputEvent) -> void:
	if on and event is InputEventJoypadButton:
		# The pad is read by polling; a focused button must not take A as "press".
		get_viewport().set_input_as_handled()
		return
	var k := event as InputEventKey
	if not k:
		return
	if k.keycode == KEY_M and not _typing():
		get_viewport().set_input_as_handled()
		if k.pressed and not k.echo:
			toggle()
		return
	if not on or not k.keycode in WALK_KEYS:
		return
	get_viewport().set_input_as_handled()
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_C:
		_mode = STAND if _mode == CROUCH else CROUCH
	elif k.keycode == KEY_Z:
		_mode = STAND if _mode == CRAWL else CRAWL
	elif k.keycode == KEY_SPACE:
		_jump_pressed = true
		_space_jumps += 1


# A text box has the keyboard: M is a letter there, not walk mode.
func _typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


# A click or tap on the floor (mouse, or touch through Godot's mouse emulation) sets the point.
func _unhandled_input(event: InputEvent) -> void:
	var b := event as InputEventMouseButton
	if not on or b == null or b.button_index != MOUSE_BUTTON_LEFT:
		return
	if b.pressed:
		_press_pos = b.position
		_press_run = b.double_click
		_press_down = true
	elif _press_down:
		_press_down = false
		if (
			b.position.distance_to(_press_pos) <= TAP_SLOP
			and walk_to_screen(b.position, _press_run)
		):
			get_viewport().set_input_as_handled()


# The floor point under a screen position: where the camera ray meets the floor the model
# stands on. False when the ray does not reach the floor (pointing at the sky).
func walk_to_screen(pos: Vector2, run: bool) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	var hit = Plane(Vector3.UP, _origin.y).intersects_ray(
		cam.project_ray_origin(pos), cam.project_ray_normal(pos)
	)
	if hit == null:
		return false
	walk_to(hit, run)
	return true


func walk_to(point: Vector3, run: bool) -> void:
	_target = Vector3(point.x, _origin.y, point.z)
	_has_target = true
	_target_run = run
	if _marker == null:
		_marker = MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.12
		ring.outer_radius = 0.16
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.78, 0.35)
		ring.material = mat
		_marker.mesh = ring
		get_parent().add_child(_marker)
	_marker.scale = Vector3.ONE * _scale
	_marker.position = _target + Vector3.UP * 0.01 * _scale
	_marker.visible = true


func _clear_target() -> void:
	_has_target = false
	if _marker:
		_marker.visible = false


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
	_clear_target()
	remove_from_group("walk_mode")
	if _player:
		_player.stop()
	# The model stays where the walk left it (it used to jump back to where it started).
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
	if walk.has_meta("mm_calibration"):
		# The clips are in place already (walk mode ran on this file before): reuse the numbers.
		var c: Dictionary = walk.get_meta("mm_calibration")
		_scale = c.scale
		_phi = c.phi
		_hips_path = c.hips
		_skeleton = (
			_player.get_node(_player.root_node).get_node_or_null(
				NodePath(_hips_path.get_slice(":", 0))
			)
			as Skeleton3D
		)
		return _skeleton != null
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
	if _skeleton == null:
		_fail("the walk clip does not move a skeleton bone")
		return false
	_rest_to_t_pose()
	_space_arms()
	_in_place()
	walk.set_meta("mm_calibration", {scale = _scale, phi = _phi, hips = _hips_path})
	return true


# Play the clips in place. Each clip's hips carry its travel and its heading (mm.elf's root: the
# hips on the floor, facing their smoothed forward). Played as they are, a cross-fade between two
# clips mixes two places and two headings: the body flies toward where the old clip was and swings
# back (seen: up to 14.8 m off for 0.2 s at each switch). So take the root out of every clip, as
# mm.elf measures it, and put the character where mm.elf says, facing its way.
func _in_place() -> void:
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var parent := _skeleton.get_bone_parent(hips)
	var up := Transform3D.IDENTITY if parent < 0 else _skeleton.get_bone_global_rest(parent)
	var rest_turn := _skeleton.get_bone_global_rest(hips).basis.get_rotation_quaternion()
	var path := NodePath(_hips_path)
	var stripped := 0
	for anim_name in _player.get_animation_list():
		if not anim_name.begins_with(PREFIX):
			continue
		var anim := _player.get_animation(anim_name)
		var tp := anim.find_track(path, Animation.TYPE_POSITION_3D)
		var tr := anim.find_track(path, Animation.TYPE_ROTATION_3D)
		if tp < 0 or tr < 0:
			continue
		var n := anim.track_get_key_count(tp)
		var g := []
		var fwd := PackedVector3Array()
		for k in n:
			var t := anim.track_get_key_time(tp, k)
			var local := Transform3D(
				Basis(anim.rotation_track_interpolate(tr, t)), anim.track_get_key_value(tp, k)
			)
			var w := up * local
			g.append(w)
			# The hips' forward as mm.elf reads it: the SOMA hips +Z, so undo the rig's rest frame.
			var f := (w.basis.get_rotation_quaternion() * rest_turn.inverse()) * Vector3.BACK
			fwd.append(Vector3(f.x, 0, f.z))
		# mm.elf smooths the facing over 0.25 s either side (30 fps clips: 8 keys).
		var half := 8
		var new_pos := []
		var new_rot := []
		for k in n:
			var s := Vector3.ZERO
			for i in range(max(0, k - half), min(n - 1, k + half) + 1):
				s += fwd[i]
			var yaw := atan2(s.x, s.z)
			var w: Transform3D = g[k]
			var root := Vector3(w.origin.x, 0, w.origin.z)
			var undo := Basis(Vector3.UP, -yaw)
			var placed := Transform3D(undo * w.basis, undo * (w.origin - root))
			var local := up.affine_inverse() * placed
			new_pos.append(local.origin)
			new_rot.append(local.basis.get_rotation_quaternion())
		for k in n:
			anim.track_set_key_value(tp, k, new_pos[k])
		# Rotation keys sit at the same frames as the position keys (one key a frame).
		for k in anim.track_get_key_count(tr):
			var kp := anim.track_find_key(
				tp, anim.track_get_key_time(tr, k), Animation.FIND_MODE_APPROX
			)
			if kp >= 0:
				anim.track_set_key_value(tr, k, new_rot[kp])
		stripped += 1
	print("MOVE-INPLACE clips=%d" % stripped)


# Arm rest pose. The clips assume the SOMA rest: a T-pose, arms straight out. A model bound in
# an A-pose (Mint: upper arms 40 degrees down) gets the same rotations on top of its lowered
# arms, so every pose sits 40 degrees lower and the arms go through the body. For each arm
# bone, turn its rotations so that its rest direction plays as the SOMA rest direction:
# world delta Q becomes Q * C, C taking the model's rest direction to SOMA's. Bones under the
# hand take the hand's C, so the fingers keep their place on the hand.
func _rest_to_t_pose() -> void:
	var walk := _player.get_animation(PREFIX + "walk")
	if walk.has_meta("t_pose"):
		return
	walk.set_meta("t_pose", true)
	var arms := _arm_chains()
	if arms.size() != 2:
		return
	# SOMA rest offsets: the translations of any clip's first frame (12 floats a joint).
	var xf := FileAccess.get_file_as_bytes(DIR.path_join("walk.f32")).to_float32_array()
	var off := func(j: int) -> Vector3:
		return Vector3(xf[j * 12 + 9], xf[j * 12 + 10], xf[j * 12 + 11])
	# [shoulder, upper arm, forearm, hand] -> the SOMA joint at the far end of each bone.
	var soma_left := [off.call(11), off.call(12), off.call(13), off.call(15)]
	var soma_right := [off.call(17), off.call(18), off.call(19), off.call(21)]
	var corr := {}
	var report := []
	for chain in arms:
		var left: bool = _skeleton.get_bone_global_rest(chain[1]).origin.x > 0.0
		var soma: Array = soma_left if left else soma_right
		for i in 4:
			if i + 1 >= chain.size():
				# A hand with no child bone turns with the forearm.
				corr[chain[i]] = corr[chain[i - 1]]
				continue
			var a := _skeleton.get_bone_global_rest(chain[i]).origin
			var b := _skeleton.get_bone_global_rest(chain[i + 1]).origin
			var c := Quaternion((b - a).normalized(), (soma[i] as Vector3).normalized())
			corr[chain[i]] = c
			if i == 1:
				report.append(
					"%s %.0f deg" % [_skeleton.get_bone_name(chain[i]), rad_to_deg(c.get_angle())]
				)
		var stack := Array(_skeleton.get_bone_children(chain[3]))
		while not stack.is_empty():
			var k: int = stack.pop_back()
			corr[k] = corr[chain[3]]
			stack.append_array(_skeleton.get_bone_children(k))
	var skel := _hips_path.get_slice(":", 0)
	var frame := func(b: int) -> Quaternion:
		return (
			Quaternion.IDENTITY
			if b < 0
			else _skeleton.get_bone_global_rest(b).basis.get_rotation_quaternion()
		)
	for anim_name in _player.get_animation_list():
		if not anim_name.begins_with(PREFIX):
			continue
		var anim := _player.get_animation(anim_name)
		for b in corr:
			var tr := anim.find_track(
				NodePath("%s:%s" % [skel, _skeleton.get_bone_name(b)]), Animation.TYPE_ROTATION_3D
			)
			if tr < 0:
				continue
			var p := _skeleton.get_bone_parent(b)
			var pf: Quaternion = frame.call(p)
			var of: Quaternion = frame.call(b)
			var cp: Quaternion = corr.get(p, Quaternion.IDENTITY)
			var cb: Quaternion = corr[b]
			for k in anim.track_get_key_count(tr):
				var v: Quaternion = anim.track_get_key_value(tr, k)
				var l := pf * v * of.inverse()
				var l2 := cp.inverse() * l * cb
				anim.track_set_key_value(tr, k, (pf.inverse() * l2 * of).normalized())
	print("MOVE-TPOSE ", "; ".join(report))


# Arm spacing. The clips are human: arms that hang close to a slim body. Copied onto a wide body
# (a big belly, wide hips, short arms) the same angles put the forearms and hands inside it. For
# each arm, find how far from straight down the arm must hang to clear the body at rest (mesh),
# take away how far the clips' idle already holds it out, and turn the upper arm out by the rest in
# every mm_ clip, about the body's forward axis (Mixamo's "arm spacing").
func _space_arms() -> void:
	if _skeleton == null or not _player.has_animation(PREFIX + "idle"):
		return
	var idle := _player.get_animation(PREFIX + "idle")
	if idle.has_meta("arm_spacing"):
		return
	var arms := _arm_chains()
	if arms.size() != 2:
		print("MOVE-ARMS none (no two arm chains)")
		return
	var mesh := _rest_mesh()
	var report := []
	for chain in arms:
		var need := _clear_angle(chain, mesh)
		var held := _idle_spread(chain, idle)
		var turn: float = max(0.0, need - held)
		report.append(
			(
				"%s need=%.1f held=%.1f turn=%.1f"
				% [
					_skeleton.get_bone_name(chain[1]),
					rad_to_deg(need),
					rad_to_deg(held),
					rad_to_deg(turn)
				]
			)
		)
		if turn > 0.0:
			_turn_arm(chain, turn)
	idle.set_meta("arm_spacing", true)
	print("MOVE-ARMS ", "; ".join(report))


# [shoulder, upper arm, forearm, hand, ... tip] for each arm: the chains from the bone with the
# most children above the hips (the chest) that end farthest to the side.
func _arm_chains() -> Array:
	var n := _skeleton.get_bone_count()
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var chest := -1
	for b in n:
		if _skeleton.get_bone_children(b).size() >= 3 and b != hips:
			if chest < 0 or _rest(b).origin.y > _rest(chest).origin.y:
				chest = b
	if chest < 0:
		return []
	var out := []
	for c in _skeleton.get_bone_children(chest):
		var chain := [c]
		while _skeleton.get_bone_children(chain[-1]).size() > 0:
			var best := -1
			for k in _skeleton.get_bone_children(chain[-1]):
				if best < 0 or _side(k) > _side(best):
					best = k
			chain.append(best)
		if chain.size() >= 4 and _side(chain[-1]) > 2.0 * _side(c):
			out.append(chain)
	if out.size() > 2:
		out.sort_custom(func(a, b): return _side(a[-1]) > _side(b[-1]))
		out = out.slice(0, 2)
	return out


func _rest(b: int) -> Transform3D:
	return _to_scene(_skeleton) * _skeleton.get_bone_global_rest(b)


# How far a bone sits to the side of the hips, in the floor plane.
func _side(b: int) -> float:
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var d := _rest(b).origin - _rest(hips).origin
	return Vector2(d.x, d.z).length()


# Rest mesh in scene space: positions and each vertex's heaviest bone.
func _rest_mesh() -> Dictionary:
	var pos := PackedVector3Array()
	var bone := PackedInt32Array()
	for mi in _scene.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or m.skin == null:
			continue
		var xf := _to_scene(m)
		for s in m.mesh.get_surface_count():
			var a := m.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var bi = a[Mesh.ARRAY_BONES]
			var bw = a[Mesh.ARRAY_WEIGHTS]
			if bi == null or bw == null or v.is_empty():
				continue
			var per := int(bi.size() / v.size())
			for i in v.size():
				var top := 0
				for k in per:
					if bw[i * per + k] > bw[i * per + top]:
						top = k
				var bind := int(bi[i * per + top])
				var sb := m.skin.get_bind_bone(bind)
				if sb < 0:
					sb = _skeleton.find_bone(m.skin.get_bind_name(bind))
				pos.append(xf * v[i])
				bone.append(sb)
	return {pos = pos, bone = bone}


# The bones of the body proper, which the arms must clear: the trunk from the hips up to the
# chest, and the legs (hips children whose chain reaches the floor). Not hair, skirts, tails,
# bags or the head: long hair hangs beside the arms and would push them far out.
func _core_bones(chain: Array) -> Dictionary:
	var core := {}
	var chest := _skeleton.get_bone_parent(chain[0])
	var b := chest
	while b >= 0:
		core[b] = true
		b = _skeleton.get_bone_parent(b)
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var floor_y := _rest(hips).origin.y * 0.2
	for c in _skeleton.get_bone_children(hips):
		var sub := [c]
		var reaches := false
		var i := 0
		while i < sub.size():
			if _rest(sub[i]).origin.y < floor_y:
				reaches = true
			sub.append_array(Array(_skeleton.get_bone_children(sub[i])))
			i += 1
		if reaches:
			for k in sub:
				core[k] = true
	return core


func _axis(chain: Array) -> Vector3:
	var hips := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	var side := _rest(chain[1]).origin - _rest(hips).origin
	side.y = 0
	return Vector3.DOWN.cross(side.normalized()).normalized()


# Smallest angle out from straight down at which the whole arm (shoulder joint to tip, as a
# segment half again as thick as the arm) misses every body vertex below the shoulder.
func _clear_angle(chain: Array, mesh: Dictionary) -> float:
	var core := _core_bones(chain)
	var s := _rest(chain[1]).origin
	var length := 0.0
	for i in range(1, chain.size() - 1):
		length += _rest(chain[i]).origin.distance_to(_rest(chain[i + 1]).origin)
	# Arm thickness: median distance of upper arm and forearm vertices from their bones.
	var radii := []
	var body := PackedVector3Array()
	var p: PackedVector3Array = mesh.pos
	var bo: PackedInt32Array = mesh.bone
	for i in p.size():
		var b := bo[i]
		if b == chain[1] or b == chain[2]:
			var a := _rest(b).origin
			var e := _rest(chain[chain.find(b) + 1]).origin
			radii.append(Geometry3D.get_closest_point_to_segment(p[i], a, e).distance_to(p[i]))
		elif core.has(b) and p[i].y < s.y - 0.1 * length:
			body.append(p[i])
	if radii.is_empty() or body.is_empty():
		return 0.0
	radii.sort()
	var r: float = radii[radii.size() / 2]
	# A few thousand body points are enough to find the gap, and keep this quick on big meshes.
	if body.size() > 4000:
		var few := PackedVector3Array()
		var step := body.size() / 4000.0
		for i in 4000:
			few.append(body[int(i * step)])
		body = few
	var ax := _axis(chain)
	for deg in range(0, 61):
		var tip := s + Vector3.DOWN.rotated(ax, deg_to_rad(deg)) * length
		var clear := INF
		for q in body:
			clear = min(clear, Geometry3D.get_closest_point_to_segment(q, s, tip).distance_to(q))
		# Half an arm more than touching: the forearm swings in while walking. Measured on
		# SK_CharacterMedium: arm vertices inside the body fell from 26-38% to 1.5-2.4% (idle, walk,
		# run, turn); touching (1.0) left 5-15%.
		if clear >= 1.5 * r:
			return deg_to_rad(deg)
	return deg_to_rad(60.0)


# How far out from straight down the idle clip holds the arm (shoulder joint to wrist), median.
func _idle_spread(chain: Array, idle: Animation) -> float:
	var vals := []
	var ax := _axis(chain)
	var steps := 20
	for i in steps:
		var t := idle.length * float(i) / steps
		var g := {}
		var place := func(b: int) -> Transform3D:
			var local := _skeleton.get_bone_rest(b)
			var tr := idle.find_track(
				NodePath("%s:%s" % [_hips_path.get_slice(":", 0), _skeleton.get_bone_name(b)]),
				Animation.TYPE_ROTATION_3D
			)
			if tr >= 0:
				local.basis = Basis(idle.rotation_track_interpolate(tr, t)).scaled(
					local.basis.get_scale()
				)
			return local
		# Pose relative to the chest at rest, so only the arm's own angles count.
		var xf := _rest(_skeleton.get_bone_parent(chain[0]))
		for b in chain.slice(0, 4):
			xf = xf * place.call(b)
			g[b] = xf.origin
		var d: Vector3 = g[chain[3]] - g[chain[1]]
		# Angle out from straight down within the plane across the body.
		var side := ax.cross(Vector3.DOWN)
		vals.append(atan2(d.dot(side), -d.y))
	vals.sort()
	return max(0.0, vals[vals.size() / 2])


func _turn_arm(chain: Array, angle: float) -> void:
	var parent_rest := _rest(chain[0]).basis.get_rotation_quaternion()
	var spin := Quaternion(parent_rest.inverse() * _axis(chain), angle)
	var path := NodePath(
		"%s:%s" % [_hips_path.get_slice(":", 0), _skeleton.get_bone_name(chain[1])]
	)
	for anim_name in _player.get_animation_list():
		if not anim_name.begins_with(PREFIX):
			continue
		var anim := _player.get_animation(anim_name)
		var tr := anim.find_track(path, Animation.TYPE_ROTATION_3D)
		if tr < 0:
			continue
		for k in anim.track_get_key_count(tr):
			var q: Quaternion = anim.track_get_key_value(tr, k)
			anim.track_set_key_value(tr, k, (spin * q).normalized())


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
	# Start from where the model stands and the way it faces (a second M goes on from there).
	var yaw := _scene.transform.basis.get_euler().y
	_mm.vmcall("mm_reset", 0.0, 0.0, yaw, max(0, _keys.find("idle")))
	_clip = -1
	_mode = STAND
	_jump_pressed = false
	_clear_target()
	_origin = _scene.position
	# Look down at the floor around the model so a click or tap can reach it. The camera starts
	# level at the model's feet, where every floor point is on the horizon line.
	var rot := get_parent().get_node_or_null("CamController/CamRotHelper") as Node3D
	if rot and rot.rotation.x > deg_to_rad(-10.0):
		rot.rotation.x = deg_to_rad(-25.0)
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
	# Step the controller by the real frame time. A floor here (it was 1/240 s) made the
	# character move faster than the clock above 240 fps, for example with no vsync.
	if delta <= 0.0:
		return
	var dt: float = min(delta, 1.0 / 20.0)
	var input := _input_dir()
	var running := (
		_test_run
		if _test
		else (
			Input.is_key_pressed(KEY_SHIFT) or Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.5
		)
	)
	if _test and not _keys_testing:
		_mode = _test_mode
		_jump_pressed = _jump_pressed or _test_jump
		_test_jump = false
	# The right stick turns the camera.
	# Walk to the tapped point unless a move key or the stick takes over.
	var steer := Vector3.ZERO
	if input != Vector2.ZERO:
		_clear_target()
	elif _has_target:
		var to := _target - _last_world
		to.y = 0.0
		if to.length() < ARRIVE * _scale:
			_clear_target()
		else:
			steer = to.normalized()
			running = running or _target_run
	var cc0 := get_parent().get_node_or_null("CamController") as Node3D
	var rx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	if cc0 and abs(rx) > 0.2 and not _test:
		cc0.rotate_y(-rx * 2.0 * dt)
	# Clip speeds are SOMA metres a second; the scene is the rig's size. Only standing runs.
	var base: float = (
		_mode_speed[_mode] if _mode != STAND else (_run_speed if running else _walk_speed)
	)
	var speed := base * _scale * (1.0 if steer != Vector3.ZERO else input.length())
	# Camera-relative input in the scene: forward is away from the camera, on the floor.
	var cam := get_viewport().get_camera_3d()
	var fwd := Vector3(0, 0, -1)
	var right := Vector3(1, 0, 0)
	# The test goes through the camera too, so it checks what a player sees.
	if cam:
		fwd = -cam.global_transform.basis.z
		fwd.y = 0
		fwd = fwd.normalized() if fwd.length() > 1e-4 else Vector3(0, 0, -1)
		right = Vector3(-fwd.z, 0, fwd.x)
	var want := (
		(fwd * input.y + right * input.x).normalized() * speed if speed > 0 else Vector3.ZERO
	)
	if steer != Vector3.ZERO:
		want = steer * speed
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
	# Place the model: the clips play in place (hips over the skeleton's origin, facing +Z), so
	# turn it to the character's facing and put that origin on the character.
	var char_scene := Vector3(r[2], 0, r[3]).rotated(Vector3.UP, _phi) * _scale + _origin
	var basis := Basis(Vector3.UP, float(r[4]))
	var o := basis * (_to_scene(_skeleton) * Vector3.ZERO)
	_scene.transform = Transform3D(basis, char_scene - Vector3(o.x, 0, o.z))
	if _trace:
		var hb := _skeleton.find_bone(_hips_path.get_slice(":", 1))
		var hw := (_skeleton.global_transform * _skeleton.get_bone_global_pose(hb)).origin
		print(
			(
				"MOVE-TRACE %d %s t=%.3f pos=%.3f hips=%.3f,%.3f char=%.3f,%.3f"
				% [
					Engine.get_process_frames(),
					name,
					t,
					_player.current_animation_position,
					hw.x,
					hw.z,
					char_scene.x,
					char_scene.z
				]
			)
		)
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
	var keys_ok := await _key_test()
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
	var ok := keys_ok
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
		# The body must not leap: in one frame the hips may move at most 1.5 times what running
		# does in the longest frame (a clip switch used to throw them metres, then back).
		var hips_prev := _hips_world()
		var leap := 0.0
		# Judge the second half of each step: the first half is the change of direction.
		var p0 := _last_world
		while t < step[3]:
			await get_tree().process_frame
			var dt := get_process_delta_time()
			t += dt
			seen[_keys[_clip]] = true
			jumped = jumped or _jumping
			var hw := _hips_world()
			var step_m := Vector2(hw.x - hips_prev.x, hw.z - hips_prev.z).length()
			# In units of the longest honest frame step: running for the 1/20 s frame cap.
			leap = max(leap, step_m / (_run_speed * _scale / 20.0))
			hips_prev = hw
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
		# Heading as the player sees it: 0 = away from the camera, 90 = to its right.
		var cam := get_viewport().get_camera_3d()
		var cf := -cam.global_transform.basis.z if cam else Vector3(0, 0, -1)
		cf = Vector3(cf.x, 0, cf.z).normalized()
		var cr := Vector3(-cf.z, 0, cf.x)
		var heading: float = rad_to_deg(atan2(moved.dot(cr), moved.dot(cf)))
		# Facing: the model's own forward (rest +Z turned by the scene) against the way it went.
		var face := _scene.global_transform.basis * (_to_scene(_skeleton).basis * Vector3.BACK)
		var face_off: float = (
			rad_to_deg(Vector2(moved.x, moved.z).angle_to(Vector2(face.x, face.z)))
			if moved.length() > 0.01
			else 0.0
		)
		var off: float = abs(wrapf(heading - step[4], -180.0, 180.0))
		var share: float = kind_ok / kind_all if kind_all > 0.0 else 0.0
		# Too fast fails too: a controller step that does not follow the frame time overshoots
		# at high frame rates (seen: 5.0 for 1.76 on Windows with no vsync).
		var good: bool = (
			speed < 0.2 * _scale
			if want == 0.0
			else (
				speed > 0.6 * want and speed < 1.25 * want and off < 25.0 and abs(face_off) < 60.0
			)
		)
		if step[6]:
			good = jumped and air > 0.1
		elif step[5] != STAND:
			good = good and share >= 0.7
		good = good and leap < 1.5
		print(
			(
				"MOVE-STEP %s speed=%.2f want=%.2f heading=%.0f facing_off=%.0f leap=%.2f kind_share=%.2f air=%.2f clips=%s %s"
				% [
					step[0],
					speed,
					want,
					heading,
					face_off,
					leap,
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
	# Walk to a point: a real left click on the floor, sent through the input queue, then a double
	# click to run. Pass = the model gets there and stops there.
	var walked := 0.0
	for tap in [["tap-walk", false], ["tap-run", true]]:
		var took: float = await _test_tap(tap[0], tap[1])
		# Running there must be clearly quicker than walking the same distance.
		var good: bool = took > 0.0 and (not tap[1] or took < 0.8 * walked)
		if tap[1]:
			print(
				(
					"MOVE-STEP tap-quicker run=%.2fs walk=%.2fs %s"
					% [took, walked, "ok" if good else "BAD"]
				)
			)
		walked = took if not tap[1] else walked
		if shots != "":
			get_viewport().get_texture().get_image().save_png(shots + "-%s.png" % tap[0])
		ok = ok and good
	print("MOVE-OK" if ok else "MOVE-FAIL")
	get_tree().quit(0 if ok else 1)


# Seconds to get to a clicked point and stop there, or -1 on a failure.
func _test_tap(name: String, run: bool) -> float:
	var cam := get_viewport().get_camera_3d()
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0, fwd.x)
	var goal := _last_world + (fwd * 2.5 + right * 0.5) * _scale
	var pos := cam.unproject_position(goal)
	if cam.is_position_behind(goal) or not get_viewport().get_visible_rect().has_point(pos):
		print("MOVE-STEP %s BAD the point is off screen" % name)
		return -1.0
	_test_input = Vector2.ZERO
	_test_run = false
	_test_mode = STAND
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.double_click = run and pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await get_tree().process_frame
	if not _has_target:
		print("MOVE-STEP %s BAD the click set no point" % name)
		return -1.0
	var set_err := Vector2(_target.x - goal.x, _target.z - goal.z).length()
	var t := 0.0
	var arrived := -1.0
	while t < 8.0:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		if arrived < 0.0 and not _has_target:
			arrived = t
		if arrived >= 0.0 and t > arrived + 2.0:
			break
	var off := Vector2(_last_world.x - goal.x, _last_world.z - goal.z).length() / _scale
	var good := arrived >= 0.0 and off < 2.0 * ARRIVE and set_err < 0.05 * _scale
	print(
		(
			"MOVE-STEP %s arrived=%.2fs off=%.2fm set_err=%.3fm %s"
			% [name, arrived, off, set_err / _scale, "ok" if good else "BAD"]
		)
	)
	return arrived if good else -1.0


func _hips_world() -> Vector3:
	var b := _skeleton.find_bone(_hips_path.get_slice(":", 1))
	return (_skeleton.global_transform * _skeleton.get_bone_global_pose(b)).origin


# Walk keys go to the walk only: with the Loop toggle focused, Space jumps and does not flip the
# toggle, and C crouches and does not show the colour chart. Sends real key events.
func _key_test() -> bool:
	var chart := get_tree().root.find_child("ColorCharts", true, false) as Node3D
	var toggle_btn: CheckButton = null
	for b in get_tree().root.find_children("*", "CheckButton", true, false):
		if (b as CheckButton).text == "Loop":
			toggle_btn = b
	var chart_was: bool = chart.visible if chart else false
	var loop_was: bool = toggle_btn.button_pressed if toggle_btn else false
	_keys_testing = true
	var jumps0 := _space_jumps
	if toggle_btn:
		toggle_btn.grab_focus()
	for key in [KEY_C, KEY_SPACE]:
		for down in [true, false]:
			var e := InputEventKey.new()
			e.keycode = key
			e.physical_keycode = key
			e.pressed = down
			Input.parse_input_event(e)
			await get_tree().process_frame
	await get_tree().process_frame
	var crouched := _mode == CROUCH
	var jumped := _space_jumps > jumps0
	_keys_testing = false
	_jump_pressed = false
	var chart_same: bool = chart == null or chart.visible == chart_was
	var loop_same: bool = toggle_btn == null or toggle_btn.button_pressed == loop_was
	_mode = STAND
	if toggle_btn:
		toggle_btn.release_focus()
	var good := (
		crouched and jumped and chart_same and loop_same and chart != null and toggle_btn != null
	)
	print(
		(
			"MOVE-STEP keys crouched=%s jumped=%s chart_unchanged=%s loop_unchanged=%s found=%s,%s %s"
			% [
				crouched,
				jumped,
				chart_same,
				loop_same,
				chart != null,
				toggle_btn != null,
				"ok" if good else "BAD"
			]
		)
	)
	return good
