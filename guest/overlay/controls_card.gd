extends Control
# A card that shows the viewer's controls as pictures: a mouse with the button that does the
# action lit, key caps for the keys, a file for drop. The rows are the controls CamController.gd
# and UIController.gd actually read; keep them in step. H shows or hides the card.

const INK := Color(0.13, 0.13, 0.13)
const MUTE := Color(0.46, 0.46, 0.46)
const LINE := Color(0.78, 0.78, 0.76)
const LIT := Color(0.16, 0.47, 0.85)
const CARD := Color(0.985, 0.985, 0.98, 0.94)
const ROW := 34.0
const PAD := 14.0
const ICON_W := 40.0

# kind: "mouse" (part = left / right / middle / wheel), "keys" (part = key names), "file".
const ROWS := [
	["mouse", "right", "Right-drag", "Orbit"],
	["mouse", "middle", "Middle-drag", "Pan"],
	["mouse", "wheel", "Scroll", "Zoom"],
	["mouse", "left", "Click a mesh", "Mesh details"],
	["keys", ["W"], "W", "Wireframe"],
	["keys", ["E"], "E", "Explode meshes"],
	["keys", ["G"], "G", "Hide grid"],
	["keys", ["Esc"], "Esc", "Close a popup"],
	["keys", ["C"], "C", "Colour chart"],
	["file", "", "Drop a file", ".glb .gltf .vrm"],
]

var font: Font


func _ready() -> void:
	font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(300, PAD * 2 + 22 + ROW * ROWS.size() + 18)
	size = custom_minimum_size


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_H:
		visible = not visible


func _draw() -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = CARD
	box.border_color = LINE
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	draw_style_box(box, Rect2(Vector2.ZERO, size))
	draw_string(font, Vector2(PAD, PAD + 13), "CONTROLS", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTE)
	var y := PAD + 22.0
	for r in ROWS:
		var c := Vector2(PAD + ICON_W * 0.5, y + ROW * 0.5)
		match r[0]:
			"mouse":
				# Drawn 1.3x about its centre so the lit button reads at a glance.
				draw_set_transform(c * (1.0 - 1.3), 0.0, Vector2(1.3, 1.3))
				_mouse(c, r[1])
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			"keys":
				_key(c, r[1][0])
			"file":
				_file(c)
		draw_string(
			font,
			Vector2(PAD + ICON_W + 10, y + ROW * 0.5 + 5),
			r[2],
			HORIZONTAL_ALIGNMENT_LEFT,
			110,
			13,
			INK
		)
		draw_string(
			font,
			Vector2(PAD + ICON_W + 124, y + ROW * 0.5 + 5),
			r[3],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			13,
			MUTE
		)
		y += ROW
	draw_string(
		font,
		Vector2(PAD, size.y - PAD + 2),
		"H  show or hide this card",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		11,
		MUTE
	)


# A mouse 16x24 seen from above: two buttons and a wheel; the part used is filled.
func _mouse(c: Vector2, part: String) -> void:
	var r := Rect2(c - Vector2(8, 12), Vector2(16, 24))
	var body := StyleBoxFlat.new()
	body.bg_color = Color(1, 1, 1)
	body.border_color = INK
	body.set_border_width_all(1)
	body.set_corner_radius_all(8)
	draw_style_box(body, r)
	var top := r.position.y
	var mid := r.position.x + 8
	# The lit button: its half of the mouse above the split, inside the rounded outline.
	if part == "left":
		draw_colored_polygon(
			PackedVector2Array(
				[
					Vector2(mid, top + 1),
					Vector2(mid, top + 10),
					Vector2(r.position.x + 1, top + 10),
					Vector2(r.position.x + 1, top + 7),
					Vector2(r.position.x + 3, top + 3),
					Vector2(mid - 3, top + 1)
				]
			),
			LIT
		)
	elif part == "right":
		draw_colored_polygon(
			PackedVector2Array(
				[
					Vector2(mid, top + 1),
					Vector2(mid + 3, top + 1),
					Vector2(r.end.x - 3, top + 3),
					Vector2(r.end.x - 1, top + 7),
					Vector2(r.end.x - 1, top + 10),
					Vector2(mid, top + 10)
				]
			),
			LIT
		)
	draw_line(Vector2(mid, top + 1), Vector2(mid, top + 10), INK, 1)
	draw_line(Vector2(r.position.x + 1, top + 10), Vector2(r.end.x - 1, top + 10), INK, 1)
	var wheel := Rect2(mid - 1.5, top + 3, 3, 6)
	draw_rect(wheel, LIT if part in ["middle", "wheel"] else Color(1, 1, 1))
	draw_rect(wheel, INK, false, 1)
	if part == "wheel":
		draw_line(Vector2(c.x + 12, top + 2), Vector2(c.x + 12, top + 10), LIT, 1.5)
		draw_line(Vector2(c.x + 9, top + 5), Vector2(c.x + 12, top + 2), LIT, 1.5)
		draw_line(Vector2(c.x + 15, top + 5), Vector2(c.x + 12, top + 2), LIT, 1.5)
		draw_line(Vector2(c.x + 9, top + 7), Vector2(c.x + 12, top + 10), LIT, 1.5)
		draw_line(Vector2(c.x + 15, top + 7), Vector2(c.x + 12, top + 10), LIT, 1.5)
	elif part in ["right", "middle"]:
		# Drag arrows beside the mouse.
		draw_line(Vector2(c.x + 11, c.y + 6), Vector2(c.x + 19, c.y + 6), LIT, 1.5)
		draw_line(Vector2(c.x + 16, c.y + 3), Vector2(c.x + 19, c.y + 6), LIT, 1.5)
		draw_line(Vector2(c.x + 16, c.y + 9), Vector2(c.x + 19, c.y + 6), LIT, 1.5)


func _key(c: Vector2, label: String) -> void:
	var w := maxf(22.0, font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 10)
	var r := Rect2(c - Vector2(w * 0.5, 11), Vector2(w, 22))
	var cap := StyleBoxFlat.new()
	cap.bg_color = Color(1, 1, 1)
	cap.border_color = INK
	cap.set_border_width_all(1)
	cap.border_width_bottom = 3
	cap.set_corner_radius_all(4)
	draw_style_box(cap, r)
	var ts := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
	draw_string(
		font, Vector2(c.x - ts.x * 0.5, c.y + 3), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK
	)


func _file(c: Vector2) -> void:
	var p := c - Vector2(8, 11)
	var pts := PackedVector2Array(
		[p, p + Vector2(11, 0), p + Vector2(16, 5), p + Vector2(16, 22), p + Vector2(0, 22), p]
	)
	draw_colored_polygon(pts, Color(1, 1, 1))
	draw_polyline(pts, INK, 1)
	draw_line(p + Vector2(11, 0), p + Vector2(11, 5), INK, 1)
	draw_line(p + Vector2(11, 5), p + Vector2(16, 5), INK, 1)
	draw_line(c + Vector2(0, -3), c + Vector2(0, 7), LIT, 1.5)
	draw_line(c + Vector2(-3, 4), c + Vector2(0, 7), LIT, 1.5)
	draw_line(c + Vector2(3, 4), c + Vector2(0, 7), LIT, 1.5)
