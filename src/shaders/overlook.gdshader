shader_type canvas_item;
// "Overlook" ghost of the 1-player sub-menu (CStuff.xs overlook_): a white copy of the row
// text that contracts towards a pivot column and fades over 70 frames, leaving a trail
// (previous frames decay by 0.9 per frame; approximated with the max over recent steps).
uniform float step_index = 0.0;   // 0..69
uniform float pivot = 90.0;       // pixel x inside the word
uniform vec2 tex_size = vec2(298.0, 37.0);

float sample_alpha(sampler2D tex, vec2 px, float s) {
	float shading = 1.0 - clamp(s / 70.0, 0.0, 1.0);
	float x_factor = 1.0 - s / 700.0;
	float y_factor = 1.0 - s / 150.0 * min(pivot, abs(px.x - pivot) + pivot / 3.0) / pivot;
	float xs = pivot + (px.x - pivot) * x_factor;
	float ys = tex_size.y / 2.0 + (px.y - tex_size.y / 2.0) * y_factor;
	vec2 uv = vec2(xs, ys) / tex_size;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 0.0;
	}
	return texture(tex, uv).a * shading;
}

void fragment() {
	vec2 px = UV * tex_size;
	float a = 0.0;
	for (int k = 0; k < 10; k++) {
		float s = step_index - float(k);
		if (s < 0.0) { break; }
		a = max(a, sample_alpha(TEXTURE, px, s) * pow(0.9, float(k)));
	}
	COLOR = vec4(1.0, 1.0, 1.0, a);
}
