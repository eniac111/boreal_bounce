shader_type canvas_item;
// Screen transition: this node shows the OLD screen on top of the new one and punches
// holes into it following a threshold mask, like the store/bars/squares/circle/plasma
// effects of the original CStuff.xs. A pixel disappears once mask <= progress.
uniform sampler2D mask_tex : filter_nearest, repeat_disable;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform bool reverse = false;
uniform bool flip_x = false;
uniform bool flip_y = false;

void fragment() {
	vec2 uv = UV;
	if (flip_x) { uv.x = 1.0 - uv.x; }
	if (flip_y) { uv.y = 1.0 - uv.y; }
	float m = texture(mask_tex, uv).r;
	if (reverse) { m = 1.0 - m; }
	float keep = m <= progress ? 0.0 : 1.0;
	COLOR = texture(TEXTURE, UV) * vec4(1.0, 1.0, 1.0, keep);
}
