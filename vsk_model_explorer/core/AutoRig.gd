extends Node
# Desktop auto-rig: R rigs the open model with skintokens.elf in the godot-sandbox add-on, on a
# local RenderingDevice (Vulkan, Metal or D3D12), and opens the result. The weights are the three
# GGUF files in the folder `w` beside the program. The rigged GLB is saved beside the source
# file as <name>.rigged.glb, or in the user folder if that one is read-only.
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

var source := ""
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
		print("AUTO-RIG-OPENED")
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


func show_status(text: String) -> void:
	_label.text = text
	_label.get_parent().visible = text != ""
	if _test and text != "" and not text.begins_with("Auto-rig: "):
		printerr("AUTO-RIG-FAIL ", text)


func start() -> void:
	if busy:
		return
	if source == "":
		return show_status("Open a .glb file first, then press R.")
	if source.get_extension().to_lower() != "glb":
		return show_status("Auto-rig reads .glb files only.")
	for f in ["mesh-encoder.gguf", "skin-vae.gguf", "tokenrig.gguf"]:
		if not FileAccess.file_exists(weights_dir().path_join(f)):
			return show_status("Auto-rig needs %s in %s." % [f, weights_dir()])
	if not ClassDB.class_exists("Sandbox"):
		return show_status("Auto-rig needs the godot-sandbox library beside the program.")
	busy = true
	var out := await run(source)
	busy = false
	if out != "":
		show_status("")
		_test_rigged = true
		rigged.emit(out)


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
	var feed := PackedByteArray()
	while true:
		var r = _sb.vmcall("skintokens_pump", feed)
		feed = PackedByteArray()
		if typeof(r) != TYPE_ARRAY or r.size() < 3:
			return fail("the rig program stopped")
		var hdr: PackedInt64Array = r[0]
		match hdr[0]:
			DONE:
				break
			ERROR:
				return fail(str(r[1]).strip_edges())
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
						return fail("could not load the weights to the GPU")
					done += n
			_:
				return fail("unknown request %d" % hdr[0])
	var size := int(_sb.vmcall("skintokens_result_size"))
	var glb := PackedByteArray()
	while glb.size() < size:
		var chunk: PackedByteArray = _sb.vmcall(
			"skintokens_result_chunk", glb.size(), size - glb.size()
		)
		if chunk.is_empty():
			return fail("the result is incomplete")
		glb.append_array(chunk)
	cleanup()
	var out := mesh.get_basename() + ".rigged.glb"
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		out = OS.get_user_data_dir().path_join(mesh.get_file().get_basename() + ".rigged.glb")
		f = FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return fail("cannot save the result")
	f.store_buffer(glb)
	f.close()
	print("AUTO-RIG-OK %s bytes=%d ms=%d" % [out, glb.size(), Time.get_ticks_msec() - t0])
	return out


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
