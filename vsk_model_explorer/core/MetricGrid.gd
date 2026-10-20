class_name MetricGrid
extends Node3D
# Metric grid: puts the floor grid on the floor the model walks on, with its zero at the walk's
# start point, so locomotion can be read off it in an orbit view. 1 m lines, 10 cm lines,
# labels every metre along both axes, an X/Y/Z gizmo at the zero, and two floor markers that
# follow the model: yellow = the root (the point root motion moves), cyan = under the hips.
# --metric-grid turns it on at start; Shift+G turns it on and off.

const SPAN := 20
const LABEL_EVERY := 1

var _plane: MeshInstance3D
var _plane_y0 := 0.0
var _origin := Vector3.ZERO
var _root_mark: MeshInstance3D
var _hips_mark: MeshInstance3D


func _ready() -> void:
	_plane = get_parent().get_node_or_null("GizmoPlane") as MeshInstance3D
	if _plane:
		_plane_y0 = _plane.global_position.y
	_build()
	set_on("--metric-grid" in OS.get_cmdline_user_args())


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.shift_pressed and k.physical_keycode == KEY_G:
		set_on(not visible)
		get_viewport().set_input_as_handled()


func set_on(on: bool) -> void:
	visible = on
	var m := _material()
	if m:
		m.set_shader_parameter("metric", on)
		m.set_shader_parameter("grid_origin", _origin if on else Vector3.ZERO)
	if _plane:
		_plane.global_position.y = _origin.y if on else _plane_y0


# The zero of the grid: the walk's start point on the floor it walks on.
func set_origin(o: Vector3) -> void:
	_origin = o
	global_position = o
	set_on(visible)


# Each frame of the walk: the root's floor point and the hips, in the scene.
func track(root: Vector3, hips: Vector3) -> void:
	if not visible:
		return
	_root_mark.global_position = Vector3(root.x, _origin.y, root.z)
	_hips_mark.global_position = Vector3(hips.x, _origin.y, hips.z)


func _material() -> ShaderMaterial:
	if _plane == null or _plane.mesh == null:
		return null
	return _plane.mesh.surface_get_material(0) as ShaderMaterial


func _build() -> void:
	for a in [[Vector3.RIGHT, Color(1, 0.15, 0.15), "X"], [Vector3.UP, Color(0.2, 1, 0.2), "Y"],
			[Vector3.BACK, Color(0.25, 0.45, 1), "Z"]]:
		var bar := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3.ONE * 0.02 + a[0] * 0.98
		bar.mesh = box
		bar.position = a[0] * 0.5
		bar.material_override = _flat(a[1])
		add_child(bar)
		_label(a[2], a[0] * 1.08 + Vector3.UP * 0.02, a[1])
	_label("0", Vector3(0.05, 0.02, 0.05), Color.WHITE)
	for i in range(-SPAN, SPAN + 1, LABEL_EVERY):
		if i == 0:
			continue
		_label("%d m" % i, Vector3(i, 0.02, 0.06), Color(1, 0.7, 0.7))
		_label("%d m" % i, Vector3(0.06, 0.02, i), Color(0.7, 0.8, 1))
	_root_mark = _marker(Color(1, 0.85, 0.1), 0.06, 0.6)
	_hips_mark = _marker(Color(0.1, 0.9, 1), 0.04, 0.3)


func _marker(c: Color, r: float, h: float) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = r * 0.15
	cyl.bottom_radius = r
	cyl.height = h
	m.mesh = cyl
	m.material_override = _flat(c)
	m.top_level = true
	add_child(m)
	return m


func _label(t: String, at: Vector3, c: Color) -> void:
	var l := Label3D.new()
	l.text = t
	l.position = at
	l.pixel_size = 0.0015
	l.font_size = 64
	l.outline_size = 12
	l.modulate = c
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(l)


func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m
