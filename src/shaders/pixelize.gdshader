shader_type canvas_item;
// "Broken cursor" flicker of the original menu (CStuff.xs pixelize): every pixel's alpha is
// multiplied by a random factor in [0.2, 1.2] each frame.
uniform float seed = 0.0;

float rnd(vec2 p) {
	return fract(sin(dot(p + vec2(seed, seed * 0.37), vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec2 cell = floor(UV * vec2(textureSize(TEXTURE, 0)));
	float f = 0.2 + rnd(cell);
	COLOR = vec4(c.rgb, c.a * clamp(f, 0.0, 1.0));
}
