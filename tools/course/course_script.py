#!/usr/bin/env python3
"""Write the walk-mode obstacle course as a SolidCraft command script (course.json).

The course is parametric the SolidCraft way: named parameters, sketches drawn roughly and then
fixed by constraints (inferred horizontal/vertical, equal, coincident-to-axis) and by dimensions
whose values are parameter expressions, then extruded. Change a parameter in the script (or with
parameters.change) and every station rebuilds and moves along to keep its spacing.

World axes are SolidCraft's: Z up (an XZ sketch's own y axis points down, -Z, so XZ profiles
are drawn with negative y), the course runs along +X, lanes sit side by side along Y.
Lengths in mm. Run it with the SolidCraft CLI or the guest (tools/course/bake_course.gd).

    python3 tools/course/course_script.py > vsk_model_explorer/course/course.json
"""
import json
import sys

C = []


def cmd(command, /, **params):
    C.append({"command": command, "params": params})


def param(name, expr, comment):
    cmd("parameters.add", name=name, expression=expr, comment=comment)


def colour(bodies, hex_):
    cmd("appearance.assign", bodies=bodies, color=hex_)


# A closed outline on a sketch plane: points drawn roughly (the dimensions move them), with
# horizontal/vertical inferred from the rough drawing. `pin` names the point held on the sketch's
# x axis (the floor) and `at` the parameter expression for its distance from the origin along x.
def outline(sketch, plane, offset, ids, points, dims, equal=(), pin=None, at=None, on=()):
    cmd("sketch.create", plane=plane, name=sketch, offset=offset)
    if plane == "XZ":
        points = [[x, -y] for x, y in points]
    cmd("sketch.line", points=points, closed=True, ids=ids, infer=True)
    for a, b in equal:
        cmd("sketch.constraint.equal", a=a, b=b)
    for point, axis in on:
        cmd("sketch.constraint.coincident", a=point, b=axis)
    if pin:
        cmd("sketch.constraint.coincident", a=pin, b="x")
        cmd("sketch.dimension", entities=["origin", pin], type="horizontal", value=at)
    for d in dims:
        cmd("sketch.dimension", **d)
    cmd("sketch.finish")


def extrude(body, distance, sketch):
    cmd("solid.extrude", sketch=sketch, distance=distance, direction="positive",
        operation="new", body_name=body)


def length(line, value):
    return {"entities": [line], "value": value}


def h(a, b, value):
    return {"entities": [a, b], "type": "horizontal", "value": value}


def v(a, b, value):
    return {"entities": [a, b], "type": "vertical", "value": value}


def angle(a, b, value):
    return {"entities": [a, b], "type": "angle", "value": value}


# --- parameters -------------------------------------------------------------------------------
P = [
    ("lane_w", "1200 mm", "Width of one lane"),
    ("lane_gap", "200 mm", "Space between two lanes"),
    ("course_w", "3 * lane_w + 2 * lane_gap", "Width of the whole course"),
    ("between", "2000 mm", "Flat floor between two stations"),
    ("pad", "20 mm", "Thickness of the start and finish pads"),
    ("start_len", "2400 mm", "Start pad length"),
    ("tread", "300 mm", "Stair tread depth"),
    ("rise_a", "100 mm", "Lane A riser: a low step"),
    ("rise_b", "170 mm", "Lane B riser: an ordinary stair"),
    ("rise_c", "250 mm", "Lane C riser: a steep step"),
    ("landing", "1500 mm", "Stair top landing length"),
    ("stairs_x", "start_len + between", "Where the stairs start"),
    ("stairs_len", "4 * tread + landing + 4 * tread", "Stairs length, foot to foot"),
    ("ramp_rise", "1000 mm", "Height of the ramp decks"),
    ("deck", "1500 mm", "Ramp deck length"),
    ("slope_a", "10 deg", "Lane A ramp slope"),
    ("slope_b", "20 deg", "Lane B ramp slope"),
    ("slope_c", "30 deg", "Lane C ramp slope"),
    ("ramps_x", "stairs_x + stairs_len + between", "Where the ramps start"),
    ("ramps_len", "2 * ramp_rise / tan(slope_a) + deck", "Longest ramp, foot to foot"),
    ("stone_d", "500 mm", "Stepping stone diameter"),
    ("stone_h", "350 mm", "Stepping stone height"),
    ("stone_gap_1", "250 mm", "First stepping gaps"),
    ("stone_gap_2", "400 mm", "Middle stepping gaps"),
    ("stone_gap_3", "550 mm", "Last stepping gaps"),
    ("stones_x", "ramps_x + ramps_len + between", "Where the stepping stones start"),
    ("stones_len", "7 * stone_d + 2 * (stone_gap_1 + stone_gap_2 + stone_gap_3)", "Stepping stones length"),
    ("bump_w", "900 mm", "Bump chord along the course"),
    ("bump_h", "120 mm", "Bump height"),
    ("bump_gap", "500 mm", "Floor between two bumps"),
    ("bumps_x", "stones_x + stones_len + between", "Where the bumps start"),
    ("bumps_len", "4 * bump_w + 3 * bump_gap", "Bumps length"),
    ("beam_clear", "1300 mm", "Clear height under the crouch beam"),
    ("beam_d", "300 mm", "Crouch beam depth along the course"),
    ("beam_t", "200 mm", "Crouch beam thickness"),
    ("post", "150 mm", "Beam post and tunnel wall thickness"),
    ("tunnel_clear", "700 mm", "Clear height inside the crawl tunnel"),
    ("tunnel_inner", "1500 mm", "Clear width inside the crawl tunnel"),
    ("tunnel_len", "2500 mm", "Crawl tunnel length"),
    ("roof", "120 mm", "Tunnel roof thickness"),
    ("duck_x", "bumps_x + bumps_len + between", "Where the beam and tunnel start"),
    ("duck_len", "beam_d + between + tunnel_len", "Beam and tunnel length"),
    ("plat_h", "400 mm", "Jump platform height"),
    ("plat_len", "1500 mm", "Jump platform length"),
    ("jump_gap", "800 mm", "Gap to jump"),
    ("gap_x", "duck_x + duck_len + between", "Where the jump starts"),
    ("ring_d", "2400 mm", "Finish ring outer diameter"),
    ("ring_t", "150 mm", "Finish ring band width"),
    ("ring_depth", "180 mm", "Finish ring depth along the course"),
    ("finish_x", "gap_x + 2 * plat_len + jump_gap + between", "Where the finish ring stands"),
]
for p in P:
    param(*p)

# Lane centres across the course (Y): A left, B middle, C right.
LANES = {"a": "-(lane_w + lane_gap)", "b": "0 mm", "c": "lane_w + lane_gap"}

# --- start pad --------------------------------------------------------------------------------
outline("StartPad", "XY", "0 mm", ["s1", "s2", "s3", "s4"],
        [[0, -1800], [2400, -1800], [2400, 1800], [0, 1800]],
        [length("s1", "start_len"), length("s2", "course_w"), v("origin", "s1.start", "course_w / 2")],
        on=[("s1.start", "y")])
extrude("StartPad", "pad", "StartPad")
colour(["StartPad"], "#4cbf66")

# --- stairs: one profile per lane, five risers up, a landing, five down -----------------------
for lane, rise in (("a", "rise_a"), ("b", "rise_b"), ("c", "rise_c")):
    ids = ["u0", "t0", "u1", "t1", "u2", "t2", "u3", "t3", "u4", "top",
           "d0", "w0", "d1", "w1", "d2", "w2", "d3", "w3", "d4", "base"]
    pts, x, y = [], 4400, 0
    pts.append([x, y])
    for i in range(5):  # up: riser then tread (the 5th tread is the landing)
        y += 100
        pts.append([x, y])
        x += 1500 if i == 4 else 300
        pts.append([x, y])
    for i in range(5):  # down: riser then tread (the 5th tread is the base, closing)
        y -= 100
        pts.append([x, y])
        if i < 4:
            x += 300
            pts.append([x, y])
    eq = [("t0", t) for t in ("t1", "t2", "t3", "w0", "w1", "w2", "w3")]
    eq += [("u0", r) for r in ("u1", "u2", "u3", "u4", "d0", "d1", "d2", "d3", "d4")]
    outline("Stairs_" + lane, "XZ", f"{LANES[lane]} - lane_w / 2", ids, pts,
            [length("t0", "tread"), length("u0", rise), length("top", "landing")],
            equal=eq, pin="u0.start", at="stairs_x")
    extrude("Stairs_" + lane, "lane_w", "Stairs_" + lane)
colour(["Stairs_a", "Stairs_b", "Stairs_c"], "#f2a633")

# --- ramps: up at the lane's slope to a deck, down at the same slope --------------------------
for lane, slope in (("a", "slope_a"), ("b", "slope_b"), ("c", "slope_c")):
    x0 = 13000
    outline("Ramp_" + lane, "XZ", f"{LANES[lane]} - lane_w / 2", ["up", "deck", "down", "floor"],
            [[x0, 0], [x0 + 3000, 1000], [x0 + 4500, 1000], [x0 + 7500, 0]],
            [length("deck", "deck"), v("origin", "deck.start", "ramp_rise"),
             angle("floor", "up", slope), angle("floor", "down", slope)],
            pin="up.start", at="ramps_x")
    extrude("Ramp_" + lane, "lane_w", "Ramp_" + lane)
colour(["Ramp_a", "Ramp_b", "Ramp_c"], "#5999f2")

# --- stepping stones: a zigzag of posts with growing gaps -------------------------------------
cmd("sketch.create", plane="XY", name="Stones", offset="0 mm")
gaps = ["stone_gap_1", "stone_gap_1", "stone_gap_2", "stone_gap_2", "stone_gap_3", "stone_gap_3"]
along = "stones_x + stone_d / 2"
for i in range(7):
    cx = 30000 + i * 900
    cmd("sketch.circle.center", center=[cx, 150 if i % 2 else -150], diameter=500)
    c = f"c{i}"
    C[-1]["params"]["id"] = c
    if i:
        along += f" + stone_d + {gaps[i - 1]}"
    cmd("sketch.dimension", entities=[c], type="diameter", value="stone_d")
    cmd("sketch.dimension", entities=["origin", f"{c}.center"], type="horizontal", value=along)
    cmd("sketch.dimension", entities=["origin", f"{c}.center"], type="vertical", value="stone_d * 0.3")
cmd("sketch.finish")
cmd("solid.extrude", sketch="Stones", distance="stone_h", direction="positive", operation="new",
    body_name="Stones", profiles="all")
colour(["Stones"], "#d959a6")

# --- bumps: low rolling humps across the whole course -----------------------------------------
cmd("sketch.create", plane="XZ", name="Bumps", offset="-course_w / 2")
start = "bumps_x"
for i in range(4):
    x0 = 40000 + i * 1400
    cmd("sketch.line", points=[[x0, 0], [x0 + 900, 0]], ids=[f"b{i}"], infer=True)
    cmd("sketch.arc.three_point", start=f"b{i}.end", end=f"b{i}.start", through=[x0 + 450, -120])
    C[-1]["params"]["id"] = f"a{i}"
    cmd("sketch.constraint.coincident", a=f"b{i}.start", b="x")
    cmd("sketch.dimension", entities=[f"b{i}"], value="bump_w")
    cmd("sketch.dimension", entities=["origin", f"b{i}.start"], type="horizontal",
        value=f"{start} + {i} * (bump_w + bump_gap)")
    # The arc through a chord bump_w long that rises bump_h: radius (w^2/4 + h^2) / 2h.
    cmd("sketch.dimension", entities=[f"a{i}"], type="radius",
        value="(bump_w * bump_w / 4 + bump_h * bump_h) / (2 * bump_h)")
cmd("sketch.finish")
cmd("solid.extrude", sketch="Bumps", distance="course_w", direction="positive", operation="new",
    body_name="Bumps", profiles="all")
colour(["Bumps"], "#9973e6")

# --- duck under: a beam on two posts (crouch), then a tunnel (crawl) --------------------------
outline("Beam", "YZ", "duck_x", ["g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8"],
        [[-1950, 0], [-1950, 1500], [1950, 1500], [1950, 0], [1800, 0], [1800, 1300],
         [-1800, 1300], [-1800, 0]],
        [length("g2", "course_w + 2 * post"), length("g4", "post"), length("g1", "beam_clear + beam_t"),
         v("origin", "g6.start", "beam_clear"), h("origin", "g1.start", "course_w / 2 + post")],
        equal=[("g4", "g8")])
extrude("Beam", "beam_d", "Beam")
outline("Tunnel", "YZ", "duck_x + beam_d + between", ["n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"],
        [[-900, 0], [-900, 820], [900, 820], [900, 0], [750, 0], [750, 700], [-750, 700], [-750, 0]],
        [length("n6", "tunnel_inner"), length("n4", "post"), v("origin", "n6.start", "tunnel_clear"),
         length("n1", "tunnel_clear + roof"), h("origin", "n1.start", "tunnel_inner / 2 + post")],
        equal=[("n4", "n8")])
extrude("Tunnel", "tunnel_len", "Tunnel")
colour(["Beam", "Tunnel"], "#f2664c")

# --- jump: two platforms with a gap -----------------------------------------------------------
for name, at in (("PlatformNear", "gap_x"), ("PlatformFar", "gap_x + plat_len + jump_gap")):
    outline(name, "XZ", "-course_w / 2", ["p1", "p2", "p3", "p4"],
            [[50000, 0], [50000, 400], [51500, 400], [51500, 0]],
            [length("p1", "plat_h"), length("p2", "plat_len")], pin="p1.start", at=at)
    extrude(name, "course_w", name)
colour(["PlatformNear", "PlatformFar"], "#40cccc")

# --- finish: a standing ring and a pad --------------------------------------------------------
cmd("sketch.create", plane="YZ", name="Ring", offset="finish_x")
cmd("sketch.circle.center", center=[0, 1200], diameter=2400, id="ro")
cmd("sketch.circle.center", center=[0, 1200], diameter=2100, id="ri")
cmd("sketch.constraint.concentric", a="ro", b="ri")
cmd("sketch.dimension", entities=["ro"], type="diameter", value="ring_d")
cmd("sketch.dimension", entities=["ri"], type="diameter", value="ring_d - 2 * ring_t")
cmd("sketch.dimension", entities=["origin", "ro.center"], type="vertical", value="ring_d / 2 + pad")
cmd("sketch.finish")
cmd("solid.extrude", sketch="Ring", distance="ring_depth", direction="positive", operation="new",
    body_name="FinishRing", profiles="all")
outline("FinishPad", "XY", "0 mm", ["f1", "f2", "f3", "f4"],
        [[56000, -1800], [58400, -1800], [58400, 1800], [56000, 1800]],
        [length("f1", "start_len"), length("f2", "course_w"), v("origin", "f1.start", "course_w / 2"),
         h("origin", "f1.start", "finish_x - start_len / 2")])
extrude("FinishPad", "pad", "FinishPad")
colour(["FinishRing", "FinishPad"], "#ffd933")

json.dump({"commands": C}, sys.stdout, indent=1)
sys.stdout.write("\n")
