extends Node
# Builds Model Explorer from its generated scene procedure (the main scene is an empty Node), then
# makes the first visit friendly: a light studio background instead of the procedural sky (which
# some browsers cannot draw: they show black), a sample model already loaded, and a one-line hint.
const ModelExplorerScene = preload("res://vsk_model_explorer/scene/ModelExplorer_scene.gd")
const ControlsCard = preload("res://controls_card.gd")
const SAMPLE := "res://sample/godette.glb"
const PAPER := Color(0.93, 0.93, 0.92)

var hint: Label

func _ready() -> void:
	RenderingServer.set_default_clear_color(PAPER)
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
	var msg: Control = root.get_node("Node/MessagePanel")
	msg.visible = false
	get_tree().root.add_child.call_deferred(root)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.13, 0.13, 0.13))
	hint.text = "Sample: Godette by SirRichard95 (CC BY 3.0).   Drop your own .glb, .gltf or .vrm to view it."
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
	if loads > 1:
		hint.text = "Drop another .glb, .gltf or .vrm to replace it."
