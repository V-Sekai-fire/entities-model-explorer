import bpy, sys, math, mathutils
argv = sys.argv[sys.argv.index("--") + 1:]
glb, out = argv[0], argv[1]
az = float(argv[2]) if len(argv) > 2 else 35.0
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
print("MESHES", [(o.name, len(o.data.vertices), len(o.data.polygons)) for o in meshes])
print("ARMATURES", [(o.name, len(o.data.bones)) for o in bpy.context.scene.objects if o.type == "ARMATURE"])
sc = bpy.context.scene
cam_data = bpy.data.cameras.new("cam"); cam_data.lens = 50
cam = bpy.data.objects.new("cam", cam_data); sc.collection.objects.link(cam); sc.camera = cam
target = mathutils.Vector((0, 0, 0.9))
r = 4.2; a = math.radians(az)
cam.location = target + mathutils.Vector((r * math.sin(a), -r * math.cos(a), 0.35))
cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
for name, loc, energy in (("key", (2.5, -3, 4), 900), ("fill", (-3, -2, 2), 350), ("rim", (0, 3, 3), 400)):
    L = bpy.data.lights.new(name, "AREA"); L.energy = energy; L.size = 2.5
    o = bpy.data.objects.new(name, L); o.location = loc; sc.collection.objects.link(o)
    o.rotation_euler = (mathutils.Vector((0, 0, 1)) - o.location).to_track_quat("-Z", "Y").to_euler()
world = bpy.data.worlds.new("w"); sc.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.58, 0.62, 1); world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
bpy.ops.mesh.primitive_plane_add(size=6)
sc.render.engine = "CYCLES"; sc.cycles.samples = 64; sc.cycles.device = "CPU"
sc.render.resolution_x = 900; sc.render.resolution_y = 1200
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
print("WROTE", out)
