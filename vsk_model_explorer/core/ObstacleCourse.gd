class_name ObstacleCourse
extends Node3D
# The walk-mode obstacle course: a game-like run of stations (stairs, ramps, stepping stones,
# bumps, a beam and a tunnel to duck under, a jump gap, a finish ring), baked by the SolidCraft
# CAD kernel with tools/course/bake_course.gd. Laid out in metres for a 1.75 m person along -Z;
# placed at the walk's start, turned to face away from the camera and scaled to the model.
# O or --obstacle-course turns it on; the walk then follows the ground under the model.

const SCENE := "res://vsk_model_explorer/course/obstacle_course.glb"
const STATIONS := "res://vsk_model_explorer/course/obstacle_course.json"
# The highest ledge the walk steps onto (a 1.75 m person's 45 cm): anything higher stays a wall
# for the ground probe, so the model walks under a beam rather than onto it.
const STEP_UP := 0.45

var _course: Node3D
var _scale := 1.0


func _ready() -> void:
	visible = "--obstacle-course" in OS.get_cmdline_user_args()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and not k.shift_pressed and k.physical_keycode == KEY_O:
		set_on(not visible)
		get_viewport().set_input_as_handled()


func set_on(on: bool) -> void:
	visible = on
	if on and _course == null:
		_build()
	if _course:
		for b in _course.find_children("*", "StaticBody3D", true, false):
			(b as StaticBody3D).process_mode = (
				Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
			)
			(b as CollisionObject3D).collision_layer = 1 if on else 0


# Put the course's start at `origin`, its -Z along `forward` (on the floor), sized by `scale`.
func place(origin: Vector3, forward: Vector3, scale_: float) -> void:
	_scale = scale_
	var f := Vector3(forward.x, 0, forward.z)
	f = f.normalized() if f.length() > 1e-4 else Vector3(0, 0, -1)
	var yaw := atan2(-f.x, -f.z)
	global_transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_), origin)
	set_on(visible)


# The floor height under p: the highest course top within STEP_UP of the current height, else
# the floor. Walls and roofs higher than a step are left out.
func ground(p: Vector3, floor_y: float) -> float:
	if not visible or _course == null:
		return floor_y
	var space := get_world_3d().direct_space_state
	var from := Vector3(p.x, p.y + STEP_UP * _scale, p.z)
	var q := PhysicsRayQueryParameters3D.create(from, Vector3(p.x, floor_y - 0.01, p.z))
	q.collision_mask = 1
	var hit := space.intersect_ray(q)
	return max(floor_y, hit.position.y) if hit else floor_y


func _build() -> void:
	var packed := load(SCENE) as PackedScene
	if packed == null:
		push_error("obstacle course missing: " + SCENE)
		return
	_course = packed.instantiate() as Node3D
	add_child(_course)
	for m in _course.find_children("*", "MeshInstance3D", true, false):
		(m as MeshInstance3D).create_trimesh_collision()
	var f := FileAccess.open(STATIONS, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text()) if f else null
	if data is Dictionary:
		for s in data.get("stations", []):
			var l := Label3D.new()
			l.text = str(s.text)
			l.position = Vector3(-2.4, 2.2, float(s.z) - 0.5)
			l.pixel_size = 0.004
			l.font_size = 48
			l.outline_size = 16
			l.width = 900.0
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			add_child(l)
