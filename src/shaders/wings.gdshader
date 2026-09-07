shader_type canvas_item;
// Fills the screen outside the 640x480 play area on wide or tall displays with procedural
// frosted ice in the colours of the current background, so the game is not letterboxed.
uniform vec3 tint_left : source_color = vec3(0.8, 0.85, 0.95);
uniform vec3 tint_right : source_color = vec3(0.8, 0.85, 0.95);
uniform vec2 content_rect_pos = vec2(0.0, 0.0);   // play area in viewport pixels
uniform vec2 content_rect_size = vec2(640.0, 480.0);
uniform vec2 viewport_size = vec2(640.0, 480.0);
uniform float time_scale = 0.02;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise(p);
		p = p * 2.1 + vec2(17.0, 9.0);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 px = UV * viewport_size;
	float side = clamp((px.x - content_rect_pos.x) / max(content_rect_size.x, 1.0), 0.0, 1.0);
	vec3 tint = mix(tint_left, tint_right, side);
	// slow drifting frost with sharper crystal veins
	vec2 p = px / 90.0 + vec2(TIME * time_scale, 0.0);
	float frost = fbm(p);
	float veins = pow(1.0 - abs(noise(p * 3.0) * 2.0 - 1.0), 6.0);
	vec3 col = tint * (0.75 + 0.35 * frost) + vec3(0.25) * veins;
	// darken towards the outer edges, and shade the border next to the play area
	float dx = min(px.x, viewport_size.x - px.x) / max(viewport_size.x, 1.0);
	float dy = min(px.y, viewport_size.y - px.y) / max(viewport_size.y, 1.0);
	float vignette = smoothstep(0.0, 0.25, min(dx, dy)) * 0.35 + 0.65;
	float dist_to_content = 0.0;
	if (px.x < content_rect_pos.x) { dist_to_content = content_rect_pos.x - px.x; }
	else if (px.x > content_rect_pos.x + content_rect_size.x) { dist_to_content = px.x - content_rect_pos.x - content_rect_size.x; }
	float shadow = 1.0 - 0.35 * exp(-dist_to_content / 24.0);
	COLOR = vec4(col * vignette * shadow, 1.0);
}
