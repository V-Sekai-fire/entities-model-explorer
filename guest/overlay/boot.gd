extends Node
# Builds Model Explorer from its generated scene procedure (the main scene is an empty Node), then
# makes the first visit friendly: a light studio background instead of the procedural sky (which
# some browsers cannot draw: they show black), a sample model already loaded, and a one-line hint.
const ModelExplorerScene = preload("res://vsk_model_explorer/scene/ModelExplorer_scene.gd")
const ControlsCard = preload("res://controls_card.gd")
const SAMPLE := "res://sample/mire.glb"
const PAPER := Color(0.93, 0.93, 0.92)

var hint: Label
var cam_rig: Node3D

func _ready() -> void:
	RenderingServer.set_default_clear_color(PAPER)
	# Wireframe view needs wireframe index buffers, which Godot only builds for meshes created after
	# this is on (the editor turns it on; an exported game does not), so the W tool drew nothing.
	RenderingServer.set_debug_generate_wireframes(true)
	var root: Node = ModelExplorerScene.new().instantiate()
	var we: WorldEnvironment = root.get_node("WorldEnvironment")
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = PAPER
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	we.camera_attributes = null
	var cam: Camera3D = root.get_node("CamController/CamRotHelper/Camera3D")
	cam.attributes = null
	root.add_child(_backdrop())
	# UIController's Grid export is never set in ModelExplorer.tscn, so Hide Grid did nothing.
	root.get_node("Node").set("Grid", root.get_node("GizmoPlane"))
	cam_rig = root.get_node("CamController/CamRotHelper")
	var msg: Control = root.get_node("Node/MessagePanel")
	msg.visible = false
	get_tree().root.add_child.call_deferred(root)
	# WebGPU has no line polygon mode, so Godot's wireframe view draws solid there. On the web the
	# Wireframe tool instead adds a line copy of every mesh (same vertices, skin and skeleton).
	if OS.has_feature("web"):
		var cb: CheckBox = root.get_node("Node/ToolPanel/MarginContainer/Row/CbWireframe")
		cb.toggled.connect(_web_wireframe)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.13, 0.13, 0.13))
	hint.text = "Sample: Mire by Mohka Noir (Apache-2.0).   Drop your own .glb, .gltf or .vrm to view it."
	var layer := CanvasLayer.new()
	layer.layer = 10
	layer.add_child(hint)
	add_child(layer)
	# Bottom left, clear of the information panel (300 px) and of the controls card on the right.
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 20)
	hint.position.x = 320
	var card: Control = ControlsCard.new()
	layer.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	root.gltf_is_loaded.connect(_on_loaded)
	await get_tree().process_frame
	await get_tree().process_frame
	root.call("_load_file", SAMPLE)
	print("BOOT built ", root.name, " sample=", SAMPLE)

var loads := 0
var wire_on := false

func _web_wireframe(on: bool) -> void:
	wire_on = on
	for n in get_tree().get_nodes_in_group("vsk_web_wire"):
		n.queue_free()
	var model_nodes: Array = get_tree().get_nodes_in_group("gltf group")
	model_nodes.append_array(get_tree().get_nodes_in_group("fbx group"))
	for model in model_nodes:
		for m in model.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.is_in_group("vsk_web_wire"):
				continue
			mi.visible = not on
			if on and mi.mesh:
				_add_wire_copy(mi)

func _edges_of(tri: PackedInt32Array) -> PackedInt32Array:
	var edges := PackedInt32Array()
	edges.resize(tri.size() * 2)
	var t := 0
	while t + 2 < tri.size():
		var a := tri[t]
		var b := tri[t + 1]
		var c := tri[t + 2]
		var e := t * 2
		edges[e] = a
		edges[e + 1] = b
		edges[e + 2] = b
		edges[e + 3] = c
		edges[e + 4] = c
		edges[e + 5] = a
		t += 3
	return edges

func _add_wire_copy(mi: MeshInstance3D) -> void:
	var lines := ArrayMesh.new()
	for s in mi.mesh.get_surface_count():
		if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var src: Array = mi.mesh.surface_get_arrays(s)
		var tri: PackedInt32Array = src[Mesh.ARRAY_INDEX]
		if tri.is_empty():
			var n: int = (src[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			tri.resize(n)
			for i in n:
				tri[i] = i
		# In slices: the compiled loop copies the arrays it indexes into guest memory, and the host
		# refuses a window over 4096 elements ("Array window: count out of range"); 1536 indices in
		# give 3072 out.
		var edges := PackedInt32Array()
		var start := 0
		while start < tri.size():
			edges.append_array(_edges_of(tri.slice(start, mini(start + 1536, tri.size()))))
			start += 1536
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = src[Mesh.ARRAY_VERTEX]
		arr[Mesh.ARRAY_BONES] = src[Mesh.ARRAY_BONES]
		arr[Mesh.ARRAY_WEIGHTS] = src[Mesh.ARRAY_WEIGHTS]
		arr[Mesh.ARRAY_INDEX] = edges
		var flags := 0
		if src[Mesh.ARRAY_BONES] != null and (src[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).size() == (src[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * 8:
			flags = Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		lines.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr, [], {}, flags)
	if lines.get_surface_count() == 0:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.15, 0.17, 0.2)
	var w := MeshInstance3D.new()
	w.name = mi.name + "_wire"
	w.mesh = lines
	w.material_override = mat
	w.transform = mi.transform
	w.skin = mi.skin
	w.skeleton = mi.skeleton  # a sibling of mi, so mi's relative skeleton path holds
	w.add_to_group("vsk_web_wire")
	mi.get_parent().add_child.call_deferred(w)

# The light background as geometry: a screen-filling quad at the far plane. Firefox's WebGPU does
# not show the render pass clear colour (the background came out black), but it draws meshes.
func _backdrop() -> MeshInstance3D:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 paper : source_color;
void vertex() {
	// Godot uses reversed depth: 0 is the far plane; stay just in front of it.
	POSITION = vec4(VERTEX.xy, 0.000001, 1.0);
}
void fragment() {
	ALBEDO = paper.rgb;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("paper", PAPER)
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	var mi := MeshInstance3D.new()
	mi.name = "Backdrop"
	mi.mesh = quad
	mi.material_override = mat
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _on_loaded(ok: bool, _scene) -> void:
	print("BOOT loaded ok=", ok)
	if not ok:
		hint.text = "That file could not be opened. Try a .glb, .gltf or .vrm."
		return
	loads += 1
	# The camera starts level with the floor grid, which then shows edge-on as nothing; look down a
	# little so the grid is visible. Deferred: CamController resets the pitch on the same signal.
	cam_rig.set_deferred("rotation", Vector3(deg_to_rad(-12.0), 0.0, 0.0))
	if loads > 1:
		hint.text = "Drop another .glb, .gltf or .vrm to replace it."
