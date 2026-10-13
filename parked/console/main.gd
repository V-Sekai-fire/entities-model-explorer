extends Node

# Cartridge loader: an uploaded (or ?cart=<url>) guest ELF becomes a slide.
# Checks, all run on the page and printed as one JSON result (window.__cart):
#   unit            telemetry.elf loads from bytes, exposes its API, and a fixed seed gives
#                   the expected trace id (expected comes from a native run: ?expect=<hex>)
#   reverse control a different seed must give a different trace id
#   contrapositive  bytes that are not an ELF are refused with an explicit error, and no
#                   slide is made

var lines: PackedStringArray = []
var slides: Array = []

func say(s: String) -> void:
	lines.append(s)
	print(s)
	$Label.text = "\n".join(lines)

func _ready() -> void:
	say("cartridge host: Sandbox class %s" % ("present" if ClassDB.class_exists("Sandbox") else "MISSING"))
	if OS.has_feature("web"):
		_install_upload_button()
	say("STEP upload button ok")
	var cart := _query("cart", "res://telemetry.elf")
	var bytes := await _fetch(cart)
	say("STEP fetched %d bytes" % bytes.size())
	var junk := PackedByteArray()
	junk.resize(4096)
	for i in junk.size():
		junk[i] = (i * 37 + 11) & 0xff
	var res := {}
	res["unit"] = _unit(bytes, _query("expect", ""))
	res["reverse_control"] = _reverse(bytes)
	res["contrapositive"] = _contra(junk)
	res["gpu"] = _gpu(await _fetch("res://rd_worker.elf"))
	var ok: bool = res.unit.pass and res.reverse_control.pass and res.contrapositive.pass and res.gpu.pass
	res["pass"] = ok
	res["slides"] = slides.size()
	say("RESULT: %s" % ("PASS" if ok else "FAIL"))
	if not OS.has_feature("web"):
		get_tree().quit()
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__cart = %s" % JSON.stringify(res), true)

# A cartridge: bytes -> Sandbox, or an explicit error. Never a half-made slide.
func load_cartridge(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 64 or bytes.slice(0, 4) != PackedByteArray([0x7f, 0x45, 0x4c, 0x46]):
		return {"error": "not an ELF (%d bytes)" % bytes.size()}
	var sb = ClassDB.instantiate("Sandbox")
	if sb == null:
		return {"error": "godot-sandbox is not loaded"}
	add_child(sb)
	sb.set_binary_translation_bg_compilation(false)
	if OS.has_feature("web"): sb.set_memory_max(int(_query("vmem", "32")))
	say("STEP mem static=%d vmem=%d" % [OS.get_static_memory_usage(), sb.get_memory_max()])
	say("STEP load_buffer start bg=%s" % sb.get_binary_translation_bg_compilation())
	sb.load_buffer(bytes)
	say("STEP load_buffer done")
	var fns: Array = sb.get_functions()
	say("STEP functions %d" % fns.size())
	if fns.is_empty():
		sb.queue_free()
		return {"error": "ELF loaded but exposes no functions"}
	slides.append(sb)
	say("bintr hash=%08X translated=%s" % [int(sb.get_translation_hash()) & 0xFFFFFFFF, "yes" if sb.is_binary_translated() else "no"])
	return {"sandbox": sb, "functions": fns}

func _trace(bytes: PackedByteArray, seed: int) -> String:
	var c := load_cartridge(bytes)
	if c.has("error"):
		return "error: " + c.error
	var sb = c.sandbox
	var init: String = sb.vmcall("init_tracer_provider", "cartridge-check", "", {"service.name": "cartridge-check"})
	if init != "":
		return "error: init " + init
	sb.vmcall("seed_ids", seed)
	sb.vmcall("set_clock", 1000000000)
	var span: String = sb.vmcall("start_span", "cartridge-check")
	return sb.vmcall("trace_id", span)

func _unit(bytes: PackedByteArray, expect: String) -> Dictionary:
	var c := load_cartridge(bytes)
	if c.has("error"):
		say("unit: FAIL (%s)" % c.error)
		return {"pass": false, "error": c.error}
	var need := ["seed_ids", "set_clock", "start_span", "trace_id"]
	var missing := need.filter(func(n): return not c.functions.has(n))
	var t := _trace(bytes, 1234567)
	var again := _trace(bytes, 1234567)
	var ok := missing.is_empty() and t.length() == 32 and t == again and (expect == "" or t == expect)
	say("unit: %s functions=%d missing=%s trace=%s repeat_same=%s expect=%s" % ["PASS" if ok else "FAIL",
			c.functions.size(), missing, t, t == again, expect if expect != "" else "(none given)"])
	return {"pass": ok, "functions": c.functions.size(), "trace": t, "expect": expect}

func _reverse(bytes: PackedByteArray) -> Dictionary:
	var a := _trace(bytes, 1234567)
	var b := _trace(bytes, 7654321)
	var ok := a != b and not b.begins_with("error")
	say("reverse control (other seed differs): %s %s vs %s" % ["PASS" if ok else "FAIL", a, b])
	return {"pass": ok, "a": a, "b": b}

# GPU cartridge: rd_worker.elf opens its own RenderingDevice from inside the guest, compiles its
# embedded SPIR-V (saxpby + a df32 dot) and checks the dot exactly (rw_round returns 1).
# Reverse control: mode 1 records the work but never submits it, so the read must be wrong (0).
func _gpu(bytes: PackedByteArray) -> Dictionary:
	var c := load_cartridge(bytes)
	if c.has("error"):
		say("gpu: FAIL (%s)" % c.error)
		return {"pass": false, "error": c.error}
	var sb = c.sandbox
	var opened: String = str(sb.vmcall("rw_open", 4096))
	var rounds := []
	for i in 3:
		rounds.append(int(sb.vmcall("rw_round", 10, 0)))
	var control := int(sb.vmcall("rw_round", 10, 1))
	var stats: String = str(sb.vmcall("rw_stats"))
	var ok := opened.begins_with("OK") and rounds == [1, 1, 1] and control == 0
	say("gpu: %s open=%s rounds=%s control(unsubmitted, want 0)=%d stats=%s" % ["PASS" if ok else "FAIL", opened.left(120), rounds, control, stats.left(160)])
	return {"pass": ok, "open": opened, "rounds": rounds, "control": control, "stats": stats}

func _contra(junk: PackedByteArray) -> Dictionary:
	var before := slides.size()
	var c := load_cartridge(junk)
	var ok: bool = c.has("error") and slides.size() == before
	say("contrapositive (junk refused, no slide): %s error=%s" % ["PASS" if ok else "FAIL", c.get("error", "<none>")])
	return {"pass": ok, "error": c.get("error", "")}

func _query(key: String, fallback: String) -> String:
	if not OS.has_feature("web"):
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--%s=" % key):
				return a.split("=", true, 1)[1]
		return fallback
	var v = JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s') || ''" % key, true)
	return v if v != "" else fallback

func _fetch(url: String) -> PackedByteArray:
	if url.begins_with("res://"):
		return FileAccess.get_file_as_bytes(url)
	var http := HTTPRequest.new()
	add_child(http)
	http.request(url)
	var r = await http.request_completed
	http.queue_free()
	return r[3] if r[1] == 200 else PackedByteArray()

# Real uploads: a file input on the page; each picked .elf becomes a new slide.
var _on_file_cb
func _install_upload_button() -> void:
	_on_file_cb = JavaScriptBridge.create_callback(_on_file)
	var win = JavaScriptBridge.get_interface("window")
	win.__cartOnFile = _on_file_cb
	JavaScriptBridge.eval("""
		(() => {
			const i = document.createElement('input');
			i.type = 'file'; i.accept = '.elf'; i.id = 'cart-upload';
			i.style = 'position:fixed;right:12px;top:12px;z-index:10';
			i.onchange = async () => {
				const f = i.files[0]; if (!f) return;
				const b = new Uint8Array(await f.arrayBuffer());
				window.__cartOnFile(f.name, Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join(''));
			};
			document.body.appendChild(i);
		})()""", true)

func _on_file(args: Array) -> void:
	var c := load_cartridge(String(args[1]).hex_decode())
	if c.has("error"):
		say("upload %s refused: %s" % [args[0], c.error])
	else:
		say("upload %s: new slide %d with %d functions" % [args[0], slides.size(), c.functions.size()])
