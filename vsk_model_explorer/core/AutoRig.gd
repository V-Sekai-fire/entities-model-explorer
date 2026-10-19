extends Node
# Desktop auto-rig: R rigs the open model with skintokens.elf in the godot-sandbox add-on, on a
# local RenderingDevice (Vulkan, Metal or D3D12), and opens the result. The weights are the three
# GGUF files in the folder `w` beside the program. The rigged GLB is saved beside the source
# file as <name>.rigged.glb, or in the user folder if that one is read-only.
# A .vrm keeps its own skeleton: R saves it as VRM 1.0 (godot-vrm), puts it in a T-pose from any
# pose and turns each joint's +Y along its bone (skintokens.elf, no weights), as <name>.tpose.vrm.
# An opened .usd, .usda, .usdc or .usdz file is rigged from the GLB the viewer made of it
# (UsdImport.gd), and the result is <name>.rigged.glb beside the USD file.
# Test mode: `-- <file.glb> --auto-rig-quit` rigs the file once it is open, opens the result,
# then quits with 0, or with 1 on any failure.

signal rigged(path: String)

const CardStyle = preload("res://vsk_model_explorer/core/CardStyle.gd")
const ELF := "res://skintokens.elf"
const WAIT_GPU := 1
const READ := 2
const UPLOAD := 3
const COOP := 4
const DONE := 5
const ERROR := 6
const UPLOAD_CHUNK := 32 << 20
const SAVED := "Auto-rig saved "
const WEIGHTS := ["mesh-encoder.gguf", "skin-vae.gguf", "tokenrig.gguf"]
const SAVED_SECONDS := 10.0
const VRM_EXTENSIONS := [
	"res://addons/vrm/vrm_extension.gd",
	"res://addons/vrm/1.0/VRMC_vrm.gd",
	"res://addons/vrm/1.0/VRMC_node_constraint.gd",
	"res://addons/vrm/1.0/VRMC_springBone.gd",
	"res://addons/vrm/1.0/VRMC_materials_hdr_emissiveMultiplier.gd",
	"res://addons/vrm/1.0/VRMC_materials_mtoon.gd",
]

var source := ""
# Where the result goes, without the extension; "" = beside `source`. An opened USD file is rigged
# from its GLB in the user folder, but its result goes beside the USD file.
var output_base := ""
var busy := false
var _sb: Node
var _rd: RenderingDevice
var _files := {}
var _label: Label
var _test := false
var _test_rigged := false


func _ready() -> void:
	_test = "--auto-rig-quit" in OS.get_cmdline_user_args()
	if _test:
		get_parent().gltf_is_loaded.connect(_on_test_loaded)
	var layer := CanvasLayer.new()
	layer.layer = 11
	add_child(layer)
	var panel := PanelContainer.new()
	panel.theme = CardStyle.make_theme()
	panel.add_theme_stylebox_override("panel", CardStyle.card_box())
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 16)
	_label = Label.new()
	panel.add_child(_label)
	layer.add_child(panel)
	panel.visible = false


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_R:
		start()


func _on_test_loaded(ok: bool, _gltf: Node) -> void:
	if not ok:
		printerr("AUTO-RIG-FAIL the model did not open")
		get_tree().quit(1)
	elif _test_rigged:
		print("AUTO-RIG-OPENED shown=%s %s" % [_label.get_parent().visible, _label.text])
		get_tree().quit(0)
	else:
		await start()
		if not _test_rigged:
			get_tree().quit(1)


func weights_dir() -> String:
	var base := OS.get_executable_path().get_base_dir()
	if OS.has_feature("editor"):
		base = ProjectSettings.globalize_path("res://")
	return base.path_join("w")


# The rig weights are in this viewer's w folder (the Kimodo motion viewer ships without them).
func available() -> bool:
	for f in WEIGHTS:
		if not FileAccess.file_exists(weights_dir().path_join(f)):
			return false
	return true


func show_status(text: String) -> void:
	_label.text = text
	_label.get_parent().visible = text != ""
	if _test and text != "" and not text.begins_with("Auto-rig: ") and not text.begins_with(SAVED):
		printerr("AUTO-RIG-FAIL ", text)


func start() -> void:
	if busy:
		return
	if source == "":
		return show_status("Open a .glb or .vrm file first, then press R.")
	var ext := source.get_extension().to_lower()
	if ext != "glb" and ext != "vrm":
		return show_status("Auto-rig reads .glb and .vrm files only.")
	if ext == "vrm":
		if not ClassDB.class_exists("Sandbox"):
			return show_status("Auto-rig needs the godot-sandbox library beside the program.")
		busy = true
		var posed := await run_vrm(source)
		busy = false
		if posed != "":
			show_saved(posed)
			_test_rigged = true
			rigged.emit(posed)
		return
	for f in WEIGHTS:
		if not FileAccess.file_exists(weights_dir().path_join(f)):
			return show_status("Auto-rig needs %s in %s." % [f, weights_dir()])
	if not ClassDB.class_exists("Sandbox"):
		return show_status("Auto-rig needs the godot-sandbox library beside the program.")
	busy = true
	var out := await run(source)
	busy = false
	if out != "":
		show_saved(out)
		_test_rigged = true
		rigged.emit(out)


# The result path stays on screen for SAVED_SECONDS, unless a newer message replaces it.
func show_saved(path: String) -> void:
	var text := SAVED + path
	show_status(text)
	await get_tree().create_timer(SAVED_SECONDS).timeout
	if _label.text == text:
		show_status("")


func run(mesh: String) -> String:
	var t0 := Time.get_ticks_msec()
	show_status("Auto-rig: starting...")
	_sb = ClassDB.instantiate("Sandbox")
	_sb.memory_max = 1024
	_sb.references_max = 4096
	_sb.allocations_max = 10000000
	_sb.execution_timeout = 0
	add_child(_sb)
	_sb.load_buffer(FileAccess.get_file_as_bytes(ELF))
	if not _sb.has_function("skintokens_start"):
		return fail("skintokens.elf did not load")
	if _rd == null:
		_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return fail("this renderer gives no local RenderingDevice")
	_sb.vmcall("skintokens_attach", _rd, 4096)
	_sb.vmcall(
		"skintokens_start", weights_dir(), mesh, "beams=1 temperature=0 GGML_RD_MAX_BUFFER_MB=128"
	)
	var glb := await drive(t0)
	if glb.is_empty():
		return ""
	cleanup()
	var base := output_base if output_base != "" else mesh.get_basename()
	var out := base + ".rigged.glb"
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		out = OS.get_user_data_dir().path_join(base.get_file() + ".rigged.glb")
		f = FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return fail("cannot save the result")
	f.store_buffer(glb)
	f.close()
	print("AUTO-RIG-OK %s bytes=%d ms=%d" % [out, glb.size(), Time.get_ticks_msec() - t0])
	return out


# Runs the started job to the end: answers its file reads and weight uploads, and returns the
# result bytes, or nothing after fail().
func drive(t0: int) -> PackedByteArray:
	var feed := PackedByteArray()
	while true:
		var r = _sb.vmcall("skintokens_pump", feed)
		feed = PackedByteArray()
		if typeof(r) != TYPE_ARRAY or r.size() < 3:
			return _stop("the rig program stopped")
		var hdr: PackedInt64Array = r[0]
		match hdr[0]:
			DONE:
				break
			ERROR:
				return _stop(str(r[1]).strip_edges())
			WAIT_GPU, COOP:
				show_status("Auto-rig: %d s" % ((Time.get_ticks_msec() - t0) / 1000))
				await get_tree().process_frame
			READ:
				feed = read(str(r[1]), hdr[1], hdr[2] if hdr[2] > 0 else 1 << 40)
			UPLOAD:
				var done := 0
				while done < hdr[2]:
					var n: int = min(hdr[2] - done, UPLOAD_CHUNK)
					var b := read(str(r[1]), hdr[1] + done, n)
					if b.size() != n or _rd.buffer_update(r[2], hdr[3] + done, n, b) != OK:
						return _stop("could not load the weights to the GPU")
					done += n
			_:
				return _stop("unknown request %d" % hdr[0])
	var size := int(_sb.vmcall("skintokens_result_size"))
	var glb := PackedByteArray()
	while glb.size() < size:
		var chunk: PackedByteArray = _sb.vmcall(
			"skintokens_result_chunk", glb.size(), size - glb.size()
		)
		if chunk.is_empty():
			return _stop("the result is incomplete")
		glb.append_array(chunk)
	return glb


func _stop(why: String) -> PackedByteArray:
	fail(why)
	return PackedByteArray()


func run_vrm(path: String) -> String:
	var t0 := Time.get_ticks_msec()
	# A VRM 1.0 already faces +Z and goes in as it is; a godot-vrm round trip can move its
	# vertices (up to 11 cm measured). A VRM 0.x is turned to +Z by godot-vrm first.
	var vrm1 := path
	if not is_vrm1(path):
		show_status("Auto-rig: saving as VRM 1.0...")
		vrm1 = OS.get_user_data_dir().path_join("vrm1.tmp.glb")
		var why := save_vrm1(path, vrm1)
		if why != "":
			return fail(why)
	_sb = ClassDB.instantiate("Sandbox")
	_sb.memory_max = 1024
	_sb.references_max = 4096
	_sb.allocations_max = 10000000
	_sb.execution_timeout = 0
	add_child(_sb)
	_sb.load_buffer(FileAccess.get_file_as_bytes(ELF))
	if not _sb.has_function("skintokens_vrm_start"):
		return fail("skintokens.elf has no VRM step")
	show_status("Auto-rig: T-pose...")
	_sb.vmcall("skintokens_vrm_start", vrm1)
	var bytes := await drive(t0)
	if vrm1 != path:
		DirAccess.remove_absolute(vrm1)
	if bytes.is_empty():
		return ""
	cleanup()
	var out := path.get_basename() + ".tpose.vrm"
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		out = OS.get_user_data_dir().path_join(path.get_file().get_basename() + ".tpose.vrm")
		f = FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return fail("cannot save the result")
	f.store_buffer(bytes)
	f.close()
	print("AUTO-RIG-OK %s bytes=%d ms=%d" % [out, bytes.size(), Time.get_ticks_msec() - t0])
	return out


# True when the file's glTF JSON carries the VRM 1.0 extension (VRMC_vrm).
func is_vrm1(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 20 or f.get_32() != 0x46546C67:
		return false
	f.seek(12)
	var size := f.get_32()
	if f.get_32() != 0x4E4F534A or size > f.get_length():
		return false
	var root = JSON.parse_string(f.get_buffer(size).get_string_from_utf8())
	return root is Dictionary and root.get("extensions", {}).has("VRMC_vrm")


# godot-vrm reads any VRM (a VRM 0.x turns to face +Z) and writes VRM 1.0. One root node: in the
# multi-root mode Godot leaves a root skeleton's root bone out of the scene, and the meshes vanish.
func save_vrm1(path: String, out: String) -> String:
	var extensions := []
	for script in VRM_EXTENSIONS:
		var e: GLTFDocumentExtension = load(script).new()
		extensions.append(e)
		GLTFDocument.register_gltf_document_extension(e)
	var why := ""
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if doc.append_from_file(path, state) != OK:
		why = "godot-vrm cannot read " + path.get_file()
	else:
		var root := doc.generate_scene(state)
		var writer := GLTFDocument.new()
		writer.root_node_mode = GLTFDocument.ROOT_NODE_MODE_SINGLE_ROOT
		var written := GLTFState.new()
		written.set_meta("vrm", "1.0")
		if writer.append_from_scene(root, written, 16) != OK:  # 16 = named skin binds
			why = "godot-vrm cannot convert " + path.get_file()
		elif writer.write_to_filesystem(written, out) != OK:
			why = "cannot write " + out
		root.queue_free()
	for e in extensions:
		GLTFDocument.unregister_gltf_document_extension(e)
	return why


func read(path: String, first: int, count: int) -> PackedByteArray:
	if not _files.has(path):
		_files[path] = FileAccess.open(path, FileAccess.READ)
	var f: FileAccess = _files[path]
	if f == null or first >= f.get_length():
		return PackedByteArray()
	f.seek(first)
	return f.get_buffer(min(count, f.get_length() - first))


func cleanup() -> void:
	_files.clear()
	# The RenderingDevice stays for the next run: the guest's GPU buffers die with the sandbox.
	if _sb:
		_sb.queue_free()
		_sb = null


func fail(why: String) -> String:
	printerr("AUTO-RIG-FAIL ", why)
	cleanup()
	show_status("Auto-rig failed: " + why)
	return ""
