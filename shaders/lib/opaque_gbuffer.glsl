vec2 decodeVec2(float a) {
	const vec2 constant1 = 65535.0 / vec2(256.0, 65536.0);
	const float constant2 = 256.0 / 255.0;
	return fract(a * constant1) * constant2;
}

vec3 decode(vec2 encn) {
	vec3 n = vec3(0.0);
	encn = encn * 2.0 - 1.0;
	n.xy = abs(encn);
	n.z = 1.0 - n.x - n.y;
	n.xy = n.z <= 0.0 ? (1.0 - n.yx) * sign(encn) : encn;
	return clamp(normalize(n), -1.0, 1.0);
}
