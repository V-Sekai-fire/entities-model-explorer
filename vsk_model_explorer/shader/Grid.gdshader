shader_type spatial;

render_mode cull_disabled, unshaded;

// Metric grid (MetricGrid.gd): lines measured from grid_origin, 1 m and 10 cm, brighter, with
// the X axis red and the Z axis blue at least 1 cm wide, and no fade within 30 m.
uniform bool metric = false;
uniform vec3 grid_origin = vec3(0.0);

float lines(vec2 coord) {
    vec2 d = fwidth(coord);
    vec2 g = abs(fract(coord - 0.5) - 0.5) / d;
    return 1.0 - min(min(g.x, g.y), 1.0);
}

vec4 metric_grid(vec3 p) {
    vec2 q = (p - grid_origin).xz;
    vec4 c = vec4(0.55, 0.55, 0.55, 0.35 * lines(q * 10.0));
    c = mix(c, vec4(0.95, 0.95, 0.95, 0.9), lines(q));
    vec2 px = fwidth(q);
    if (abs(q.y) < max(0.01, px.y))
        c = vec4(1.0, 0.15, 0.15, 1.0);
    if (abs(q.x) < max(0.01, px.x))
        c = vec4(0.25, 0.45, 1.0, 1.0);
    return c;
}

vec4 grid(vec3 fragPos3D, float scale) {
    vec2 coord = fragPos3D.xz * scale;
    vec2 derivative = fwidth(coord);
    vec2 grid = abs(fract(coord - 0.5) - 0.5) / derivative;
    float line = min(grid.x, grid.y);
    float minimumz = min(derivative.y, 1);
    float minimumx = min(derivative.x, 1);
    vec4 color = vec4(0.2, 0.2, 0.2, 1.0 - min(line, 1.0));
    // z axis
    if(fragPos3D.x > -0.1 * minimumx && fragPos3D.x < 0.1 * minimumx)
        color.z = 1.0;
    // x axis
    if(fragPos3D.z > -0.1 * minimumz && fragPos3D.z < 0.1 * minimumz)
        color.x = 1.0;
    return color;
}

void fragment() {
	vec4 pos = INV_VIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 clip_pos = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
	float clip_space_depth = (clip_pos.z / clip_pos.w) * 2.0 - 1.0;

	float near = 0.05;
	float far = 100.0;
	float linearDepth = (2.0 * near * far) / (far + near - clip_space_depth * (far - near));
	linearDepth = linearDepth / far;
	float fading = max(0, (0.5 - linearDepth));

    if (metric) {
        vec4 m = metric_grid(pos.xyz);
        float dist = length(pos.xyz - CAMERA_POSITION_WORLD);
        ALBEDO = m.rgb;
        ALPHA = m.a * clamp((60.0 - dist) / 30.0, 0.0, 1.0);
    } else {
    vec4 outColor = (grid(pos.xyz, 10) * 0.5 + grid(pos.xyz, 1));

	ALBEDO = outColor.xyz;
	ALPHA = outColor.w * fading;
    }
}
