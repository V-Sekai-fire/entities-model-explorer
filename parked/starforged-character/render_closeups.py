import bpy, sys, math, mathutils
# closeup renders: argv = glb out_prefix
argv = sys.argv[sys.argv.index("--") + 1:]
glb, prefix = argv[0], argv[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
sc = bpy.context.scene
cam_data = bpy.data.cameras.new("cam"); cam_data.lens = 85
cam = bpy.data.objects.new("cam", cam_data); sc.collection.objects.link(cam); sc.camera = cam
for name, loc, energy in (("key", (2.5, -3, 4), 900), ("fill", (-3, -2, 2), 350), ("rim", (0, 3, 3), 400)):
    L = bpy.data.lights.new(name, "AREA"); L.energy = energy; L.size = 2.5
    o = bpy.data.objects.new(name, L); o.location = loc; sc.collection.objects.link(o)
    o.rotation_euler = (mathutils.Vector((0, 0, 1)) - o.location).to_track_quat("-Z", "Y").to_euler()
world = bpy.data.worlds.new("w"); sc.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.58, 0.62, 1)
sc.render.engine = "CYCLES"; sc.cycles.samples = 32; sc.cycles.device = "CPU"
sc.render.resolution_x = 800; sc.render.resolution_y = 800
for tag, target, r, az, dz in (("face", (0, 0, 1.62), 0.9, 25, 0.0), ("legs", (0, 0, 0.25), 1.6, 30, 0.2),
                                ("torso", (0, 0, 1.2), 1.6, 0, 0.0), ("back", (0, 0, 1.0), 3.5, 160, 0.3)):
    t = mathutils.Vector(target); a = math.radians(az)
    cam.location = t + mathutils.Vector((r * math.sin(a), -r * math.cos(a), dz))
    cam.rotation_euler = (t - cam.location).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = f"{prefix}_{tag}.png"
    bpy.ops.render.render(write_still=True)
    print("WROTE", sc.render.filepath)
