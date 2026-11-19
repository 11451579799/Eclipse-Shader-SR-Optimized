#include "/lib/rtgi_light_grid.glsl"

uniform usampler3D texRtgiReceiverLights;

float rtgiLocalLightCoverage(vec3 origin) {
	vec3 border = min(origin, vec3(VoxelSize) - origin);
	float distanceToBorder = min(border.x, min(border.y, border.z));
	float distanceToCamera = length(origin - rtgiVoxelOffset());
	return smoothstep(rtgiLightRange, rtgiLightRange + 3.0, distanceToBorder)
		* (1.0 - smoothstep(rtgiLightCoverageRadius - 4.0, rtgiLightCoverageRadius, distanceToCamera));
}

float rtgiLightListConfidence(uvec4 record, ivec3 cell, vec3 origin, vec3 flatNormal) {
	if ((record.x & rtgiLightRecordFlag) == 0u) return 1.0;

	float confidence = 1.0;
	int count = int(record.w >> 29u) + 1;
	uvec4 pair = uvec4(0u);
	for (int i = 0; i < count; ++i) {
		int slot = (i % 2) * 2;
		if (slot == 0) pair = texelFetch(texRtgiReceiverLights, cell + ivec3(0, 0, (1 + i / 2) * rtgiLightGridCells), 0);
		vec3 lo = vec3(rtgiUnpackLightPosition(pair[slot]));
		vec3 hi = vec3(rtgiUnpackLightPosition(pair[slot + 1]) + 1);
		vec3 front = mix(lo, hi, greaterThanEqual(flatNormal, vec3(0.0)));
		// A group entirely behind the receiver cannot contribute direct light.
		float facing = smoothstep(-rtgiLightFallbackFade, 0.0, dot(front - origin, flatNormal));
		if (facing <= 0.0) continue;

		float range = float(pair[slot] >> 24u);
		float distanceToBounds = length(rtgiCellGap(origin, lo, hi));
		float outside = smoothstep(range, range + rtgiLightFallbackFade, distanceToBounds);
		confidence = min(confidence, mix(1.0, outside, facing));
		if (confidence <= 0.0) break;
	}
	return confidence;
}

uvec4 rtgiResolveLocalLights(vec3 origin, vec3 flatNormal, out float confidence) {
	ivec3 gridMin = rtgiLightGridMin();
	vec3 cellPosition = (origin - vec3(gridMin)) / float(rtgiLightCellSize);
	ivec3 cell = ivec3(floor(cellPosition));
	uvec4 center = texelFetch(texRtgiReceiverLights, cell, 0);
	confidence = 0.0;
	if (center.x == 0u) return center;

	vec3 withinCell = fract(cellPosition) * float(rtgiLightCellSize);
	vec3 distanceToEdge = min(withinCell, float(rtgiLightCellSize) - withinCell);
	vec3 neighborWeight = 0.5 * (1.0 - smoothstep(vec3(0.0), vec3(rtgiLightCellOverlap), distanceToEdge));
	ivec3 direction = 2 * ivec3(greaterThanEqual(withinCell, vec3(rtgiLightCellSize / 2))) - 1;
	ivec3 last = ivec3(greaterThan(neighborWeight, vec3(0.0)));
	uvec4 selected = uvec4(0u);
	for (int z = 0; z <= last.z; ++z) {
		for (int y = 0; y <= last.y; ++y) {
			for (int x = 0; x <= last.x; ++x) {
				ivec3 offset = ivec3(x, y, z);
				ivec3 neighbor = cell + offset * direction;
				uvec4 record = (x + y + z == 0) ? center : texelFetch(texRtgiReceiverLights, neighbor, 0);
				vec3 weights = mix(1.0 - neighborWeight, neighborWeight, notEqual(offset, ivec3(0)));
				float weight = rtgiLightListConfidence(record, neighbor, origin, flatNormal)
					* weights.x * weights.y * weights.z;
				confidence += weight;

				// Any trusted list in the overlap contains every light in range here.
				// Only trace one list, so blending the confidence adds no shadow rays.
				record &= rtgiPackedLightMask;
				if (weight > 0.0 && selected.x == 0u && record.x != 0u) selected = record;
			}
		}
	}
	return selected;
}

vec3 rtgiEmitterOffset(uint id) {
	if (id == BLOCK_TORCH || id == BLOCK_SOUL_TORCH || id == BLOCK_COPPER_TORCH || id == BLOCK_REDSTONE_TORCH_LIT)
		return vec3(0.5, 0.625, 0.5);
	if (id == BLOCK_LANTERN || id == BLOCK_SOUL_LANTERN || id == BLOCK_COPPER_LANTERN)
		return vec3(0.5, 0.375, 0.5);
	return vec3(0.5);
}

// RGB is the sum of individually visible lights. Alpha controls the LPV fallback.
// A valid zero sum therefore differs from a light list that could miss a contributor.
vec4 rtgiLocalLighting(vec3 position, vec3 flatNormal, vec3 normal) {
	vec3 origin = position + flatNormal * rtgiRayBias;
	float coverage = rtgiLocalLightCoverage(origin);
	if (coverage <= 0.0) return vec4(0.0);

	float confidence;
	uvec4 candidates = rtgiResolveLocalLights(origin, flatNormal, confidence);
	if (candidates.x == 0u) return vec4(0.0);

	vec3 direct = vec3(0.0);
	float influence = 0.0;
	for (int slot = 0; slot < 4; ++slot) {
		uint packedLight = candidates[slot];
		if (packedLight == 0u) break;

		ivec3 source = rtgiUnpackLightPosition(packedLight);
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
	return vec4(direct, coverage * influence * clamp(confidence, 0.0, 1.0));
}
