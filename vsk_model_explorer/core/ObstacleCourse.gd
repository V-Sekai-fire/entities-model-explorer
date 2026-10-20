class_name ObstacleCourse
extends Node3D
# The walk-mode obstacle course: a game-like run of stations (stairs, ramps, stepping stones,
# bumps, a beam and a tunnel to duck under, a jump gap, a finish ring). Its shapes are a
# parametric SolidCraft script (tools/course/course_script.py: constrained, dimensioned sketches
# extruded), built by the SolidCraft CAD kernel with tools/course/bake_course.gd. Laid out in
# metres for a 1.75 m person along -Z;
# placed at the walk's start, turned to face away from the camera and scaled to the model.
# O or --obstacle-course turns it on; the walk then follows the ground under the model.

const SCENE := "res://vsk_model_explorer/course/obstacle_course.glb"
# A sign above each station, keyed by the start of its SolidCraft body names.
const SIGNS := {
	"StartPad": "Start: walk ahead",
	"Stairs_a": "Stairs: 10, 17 and 25 cm steps",
	"Ramp_a": "Ramps: 10, 20 and 30 degrees",
	"Stones": "Stepping stones",
	"Bumps": "Bumps",
	"Beam": "Duck under: crouch, then crawl",
	"PlatformNear": "Jump the gap",
	"FinishRing": "Finish",
}
# The highest ledge the walk steps onto (a 1.75 m person's 45 cm): anything higher stays a wall
# for the ground probe, so the model walks under a beam rather than onto it.
const STEP_UP := 0.45
# The body that walls stop, for a 1.75 m person: its half width, and its height standing,
# crouching and crawling (MotionMatch's STAND, CROUCH, CRAWL).
const BODY_RADIUS := 0.25
const BODY_HEIGHT := [1.75, 1.2, 0.6]

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


# Move the body from `from` toward `to` on the floor plane, stopping at walls and sliding along
# them. The body is a box from a step above the feet to the mode's height, so steps, ramps and
# bumps stay walkable while posts, walls, the beam and the tunnel roof block.
func slide(from: Vector3, to: Vector3, mode: int, s: float) -> Vector3:
	var d := Vector3(to.x - from.x, 0, to.z - from.z)
	if not visible or _course == null or d.length() < 1e-6:
		return to
	var lo := STEP_UP * s + 0.01
	var hi: float = BODY_HEIGHT[clampi(mode, 0, 2)] * s
	var box := BoxShape3D.new()
	box.size = Vector3(BODY_RADIUS * 2.0 * s, max(hi - lo, 0.02), BODY_RADIUS * 2.0 * s)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = box
	q.collision_mask = 1
	var at := Vector3(from.x, from.y + (lo + hi) * 0.5, from.z)
	var space := get_world_3d().direct_space_state
	for i in 2:
		q.transform = Transform3D(Basis(), at)
		q.motion = d
		var f := space.cast_motion(q)
		if f.is_empty() or f[0] >= 1.0:
			at += d
			break
		at += d * f[0]
		# Slide: keep the part of the rest of the move along the wall.
		q.transform = Transform3D(Basis(), at + d * (f[1] - f[0]))
		q.motion = Vector3.ZERO
		var hit := space.get_rest_info(q)
		var n: Vector3 = hit.get("normal", Vector3.ZERO)
		n.y = 0
		if n.length() < 1e-4:
			break
		n = n.normalized()
		d *= 1.0 - f[0]
		d -= n * d.dot(n)
		if d.length() < 1e-6:
			break
	return Vector3(at.x, to.y, at.z)


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
	for m in _course.get_children():
		var mi := m as MeshInstance3D
		if mi == null or not SIGNS.has(str(mi.name)):
			continue
		var box := mi.get_aabb()
		var l := Label3D.new()
		l.text = SIGNS[str(mi.name)]
		l.position = Vector3(0, max(box.end.y, 1.0) + 0.8, box.end.z)
		# About 40 cm tall letters: readable from the far side of a station.
		l.pixel_size = 0.008
		l.font_size = 64
		l.outline_size = 16
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		add_child(l)
