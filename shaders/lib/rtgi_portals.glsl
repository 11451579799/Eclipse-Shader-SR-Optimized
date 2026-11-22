vec3 rtgiPortalPoint(ivec3 door, uint side, vec2 xi) {
	vec2 choice = floor(xi * 2.0);
	vec2 within = fract(xi * 2.0);
	float u = (3.0 + choice.x * 6.0 + within.x * 4.0) / 16.0;
	float y = (5.0 + choice.y * 5.0 + within.y * 3.0) / 16.0;
	if (side == 0u) return vec3(door) + vec3(u, y, 0.90625);
	if (side == 1u) return vec3(door) + vec3(0.09375, y, u);
	if (side == 2u) return vec3(door) + vec3(u, y, 0.09375);
	return vec3(door) + vec3(0.90625, y, u);
}

// Returns pi times the directional PDF for uniform sampling over the four holes.
float rtgiPortalPdf(vec3 point, vec3 direction, ivec3 door, uint side) {
	bool alongZ = side == 0u || side == 2u;
	float plane = alongZ ? float(door.z) + (side == 0u ? 0.90625 : 0.09375)
		: float(door.x) + (side == 1u ? 0.09375 : 0.90625);
	float denom = alongZ ? direction.z : direction.x;
	if (abs(denom) < 1e-5) return 0.0;
	float distance = (plane - (alongZ ? point.z : point.x)) / denom;
	if (distance <= 0.0) return 0.0;
	vec3 local = point + direction * distance - vec3(door);
	float u = alongZ ? local.x : local.z;
	bool holeU = (u >= 3.0 / 16.0 && u <= 7.0 / 16.0) || (u >= 9.0 / 16.0 && u <= 13.0 / 16.0);
	bool holeY = (local.y >= 5.0 / 16.0 && local.y <= 8.0 / 16.0)
		|| (local.y >= 10.0 / 16.0 && local.y <= 13.0 / 16.0);
	return holeU && holeY ? 3.141592653589793 * distance * distance / ((3.0 / 16.0) * abs(denom)) : 0.0;
}
