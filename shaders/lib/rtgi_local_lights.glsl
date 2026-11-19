#include "/lib/rtgi_light_grid.glsl"

layout(rgba32ui) uniform readonly uimage3D rtgiReceiverLights;

float rtgiLocalLightCoverage(vec3 origin) {
	vec3 border = min(origin, vec3(VoxelSize) - origin);
	float distanceToBorder = min(border.x, min(border.y, border.z));
	float distanceToCamera = length(origin - rtgiVoxelOffset());
	return smoothstep(rtgiLightRange, rtgiLightRange + 3.0, distanceToBorder)
		* (1.0 - smoothstep(rtgiLightCoverageRadius - 4.0, rtgiLightCoverageRadius, distanceToCamera));
}

vec3 rtgiEmitterOffset(uint id) {
	if (id == BLOCK_TORCH || id == BLOCK_SOUL_TORCH || id == BLOCK_COPPER_TORCH || id == BLOCK_REDSTONE_TORCH_LIT)
		return vec3(0.5, 0.625, 0.5);
	if (id == BLOCK_LANTERN || id == BLOCK_SOUL_LANTERN || id == BLOCK_COPPER_LANTERN)
		return vec3(0.5, 0.375, 0.5);
	return vec3(0.5);
}

// RGB is the sum of individually visible lights. Alpha controls the LPV fallback.
// A valid zero sum therefore differs from a missing or over-budget light list.
vec4 rtgiLocalLighting(vec3 position, vec3 flatNormal, vec3 normal) {
	vec3 origin = position + flatNormal * rtgiRayBias;
	float coverage = rtgiLocalLightCoverage(origin);
	if (coverage <= 0.0) return vec4(0.0);

	ivec3 cell = (ivec3(floor(origin)) - rtgiLightGridMin()) / rtgiLightCellSize;
	uvec4 candidates = imageLoad(rtgiReceiverLights, cell);
	if (candidates.x == 0u || candidates.x == rtgiIncompleteLights) return vec4(0.0);

	vec3 direct = vec3(0.0);
	float influence = 0.0;
	for (int slot = 0; slot < 4; ++slot) {
		uint packedLight = candidates[slot];
		if (packedLight == 0u) break;

		ivec3 source = ivec3(packedLight & 255u, (packedLight >> 8u) & 255u, (packedLight >> 16u) & 255u);
		uint id = imageLoad(imgVoxelMask, source).r;
		if (id == 0u || id >= 2000u) return vec4(0.0);

		vec3 delta = vec3(source) + rtgiEmitterOffset(id) - origin;
		float distanceSquared = dot(delta, delta);
		float range = float(packedLight >> 24u);
		if (distanceSquared >= range * range) continue;

		float distanceToLight = sqrt(max(distanceSquared, 1e-6));
		influence = max(influence, smoothstep(0.0, 1.0, range - distanceToLight));
		vec3 direction = delta / distanceToLight;
		float incidence = dot(normal, direction);
		if (incidence <= 0.0 || dot(flatNormal, direction) <= 0.0) continue;

		RtgiVoxelHit blocker;
		vec3 transmission;
		int visibility = rtgiTraceVoxels(origin, direction, distanceToLight, source, blocker, transmission);
		if (visibility == rtgiRayUnknown) return vec4(0.0);
		if (visibility == rtgiRayHit) continue;

		vec3 color = toLinear(unpackUnorm4x8(texelFetch(texBlockData, int(id), 0).r).rgb);
		color /= max(max(color.r, max(color.g, color.b)), 1e-5);
		float falloff = 1.0 - distanceSquared / (range * range);
		direct += color * transmission * (3.0 * incidence * falloff * falloff / (1.0 + distanceSquared));
	}
	return vec4(direct, coverage * influence);
}
