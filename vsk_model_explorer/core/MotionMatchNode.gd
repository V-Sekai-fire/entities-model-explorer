extends AnimationNodeExtension
# The motion-matching node of walk mode's AnimationTree. Each tree update it steps mm.elf
# (interactor-motion-matching-guest) by the frame time with the controller's input, and plays the
# clip frame mm.elf picks. A new pick cross-fades from the previous clip over BLEND seconds: the
# AnimationTree blends the two clips by weight.
# MotionMatch.gd sets the input fields before it advances the tree, and reads the output fields
# after.

const BLEND := 0.2

# Set once.
var mm: Node
var names: PackedStringArray = []  # animation name of each mm.elf clip index
# Input, set before each advance. Velocity is in SOMA metres a second.
var velocity := Vector2.ZERO
var mode := 0
var jump := false
# Output of the last step.
var clip := -1
var time := 0.0
var result := PackedFloat32Array()
var _prev := -1
var _prev_time := 0.0
var _fade := BLEND


func reset() -> void:
	clip = -1
	_prev = -1
	_fade = BLEND
	result = PackedFloat32Array()


func _process_animation_node(
	playback_info: PackedFloat64Array, test_only: bool
) -> PackedFloat32Array:
	var delta: float = playback_info[1]
	var info := PackedFloat32Array([0.0, time, delta, Animation.LOOP_NONE, 0.0, 1.0])
	if test_only or mm == null or delta <= 0.0:
		return info
	var r: PackedFloat32Array = mm.vmcall(
		"mm_step", delta, velocity.x, velocity.y, NAN, mode, 1 if jump else 0
	)
	jump = false
	if r.size() < 15:
		return info
	result = r
	var picked := int(r[0])
	var t := float(r[1])
	var seeked := false
	if picked != clip or r[8] > 0.5:
		if clip >= 0:
			_prev = clip
			_prev_time = time
			_fade = 0.0
		clip = picked
		seeked = true
	elif abs(time + delta - t) > 0.05:
		seeked = true
	time = t
	_fade += delta
	var w: float = clamp(_fade / BLEND, 0.0, 1.0)
	if _prev >= 0 and w < 1.0:
		_prev_time += delta
		blend_animation(names[_prev], _prev_time, delta, false, false, 1.0 - w)
	else:
		_prev = -1
		w = 1.0
	blend_animation(names[clip], t, delta, seeked, false, w)
	info[1] = t
	return info
