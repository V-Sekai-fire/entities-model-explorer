extends Node3D

const ZOOM_FACTOR = 1.2
const ROTATE_SPEED = 0.1
const PAN_SPEED = 0.005

@export var UiNode: Control

@onready var CamRotHelper = $CamRotHelper

var enable_cam_control: bool = true


func _ready():
	var _discard = UiNode.connect("mouse_entered", _ui_mouse_entered)
	_discard = UiNode.connect("mouse_exited", _ui_mouse_exited)

	GlobalSignal.reposition_camera.connect(_on_reposition_camera)


func _ui_mouse_entered():
	enable_cam_control = false


func _ui_mouse_exited():
	enable_cam_control = true


func _on_reposition_camera(aabb: AABB):
	if aabb.size.length() > 0:
		scale = Vector3.ONE * (aabb.size.length() * 0.2)
	else:
		scale = Vector3.ONE

	rotation = Vector3.ZERO
	CamRotHelper.rotation = Vector3.ZERO


func _unhandled_input(event):
	if not enable_cam_control:
		return

	if event is InputEventMouseMotion:
		if event.button_mask == MOUSE_BUTTON_MASK_RIGHT:
			# Rotate
			self.rotate_y(deg_to_rad(-1 * event.get_relative().x * ROTATE_SPEED))
			CamRotHelper.rotate_x(deg_to_rad(-1 * event.get_relative().y * ROTATE_SPEED))

			#Stop rotation over top or bottom
			var camera_rot = CamRotHelper.rotation
			camera_rot.x = clamp(camera_rot.x, -90, 90)
			CamRotHelper.rotation = camera_rot
		elif event.button_mask == MOUSE_BUTTON_MASK_MIDDLE:
			# Pan
			self.translate(
				Vector3(
					-1 * event.get_relative().x * PAN_SPEED, event.get_relative().y * PAN_SPEED, 0.0
				)
			)
	elif event is InputEventMouseButton and event.is_pressed():
		# Zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			self.scale_object_local(Vector3.ONE * (ZOOM_FACTOR))
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			self.scale_object_local(Vector3.ONE * (1 / ZOOM_FACTOR))


# Start framing: a three-quarter view from a little above, with a longer lens, so the whole
# model fills the free middle of the window (the panels cover the sides) with some headroom.
const FRAME_FOV := 40.0
const FRAME_YAW := 30.0
const FRAME_PITCH := -12.0
const FRAME_MARGIN := 1.15
# Share of the window width between the information panel and the controls card.
const FRAME_FREE_WIDTH := 0.55


func _on_root_gltf_is_loaded(success, _gltf):
	scale = Vector3.ONE
	rotation.y = 0
	CamRotHelper.rotation.x = 0
	if not success:
		return
	# A frame later: the model is in the tree with its transforms set.
	await get_tree().process_frame
	frame_models()


func frame_models() -> void:
	var models: Array = get_tree().get_nodes_in_group(GlobalSignal.GLTF_GROUP)
	models.append_array(get_tree().get_nodes_in_group(GlobalSignal.FBX_GROUP))
	var box := AABB()
	var first := true
	for model in models:
		for m in (model as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.mesh == null:
				continue
			var b := mi.global_transform * mi.get_aabb()
			box = b if first else box.merge(b)
			first = false
	if first:
		return
	var cam: Camera3D = CamRotHelper.get_node("Camera3D")
	cam.fov = FRAME_FOV
	var size := get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(size.y, 1.0)
	var half_v := deg_to_rad(FRAME_FOV) * 0.5
	var half_h := atan(tan(half_v) * aspect * FRAME_FREE_WIDTH)
	# The box as seen from the yaw: its width across the view and its depth along it.
	var yaw := deg_to_rad(FRAME_YAW)
	var across := absf(cos(yaw)) * box.size.x + absf(sin(yaw)) * box.size.z
	var along := absf(sin(yaw)) * box.size.x + absf(cos(yaw)) * box.size.z
	var d := maxf(
		0.5 * box.size.y * FRAME_MARGIN / tan(half_v), 0.5 * across * FRAME_MARGIN / tan(half_h)
	)
	d = maxf(d + 0.5 * along, 0.001)
	position = box.get_center()
	rotation = Vector3(0, yaw, 0)
	CamRotHelper.rotation = Vector3(deg_to_rad(FRAME_PITCH), 0, 0)
	scale = Vector3.ONE * (d / cam.position.z)
	cam.near = maxf(d * 0.005, 0.0005)
