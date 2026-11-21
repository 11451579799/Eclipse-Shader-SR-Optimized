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
	if ((record.x & rtgiPackedLightMask) == 0u) return 0.0;
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
		float facing = smoothstep(0.0, rtgiLightFallbackFade, dot(front - origin, flatNormal));
		if (facing <= 0.0) continue;

		float range = float(pair[slot] >> 24u);
		float distanceToBounds = length(rtgiCellGap(origin, lo, hi));
		float outside = smoothstep(range, range + rtgiLightFallbackFade, distanceToBounds);
		confidence = min(confidence, mix(1.0, outside, facing));
		if (confidence <= 0.0) break;
	}
	return confidence;
}

uint rtgiEmitterKey(ivec3 world, uint light) {
	uint key = uint(world.x) * 0x8da6b343u ^ uint(world.y) * 0xd8163841u ^ uint(world.z) * 0xcb1ab31fu ^ light * 0x165667b1u;
	return (key ^ (key >> 16u)) * 0x7feb352du;
}

uint rtgiLightListKey(uvec4 record, ivec3 worldOrigin) {
	uvec3 base = uvec3(worldOrigin);
	uvec4 key = ((record & 255u) + base.x) * 0x8da6b343u
		^ (((record >> 8u) & 255u) + base.y) * 0xd8163841u
		^ (((record >> 16u) & 255u) + base.z) * 0xcb1ab31fu
		^ (record >> 24u) * 0x165667b1u;
	key = (key ^ (key >> 16u)) * 0x7feb352du * uvec4(notEqual(record, uvec4(0u)));
	return key.x ^ key.y ^ key.z ^ key.w;
}

uvec4 rtgiResolveLocalLights(vec3 origin, vec3 flatNormal, bool useFallbackConfidence,
	float cellSample, out float confidence, out uint blendKey) {
	ivec3 gridMin = rtgiLightGridMin();
	vec3 cellPosition = (origin - vec3(gridMin)) / float(rtgiLightCellSize);
	ivec3 cell = ivec3(floor(cellPosition));
	confidence = 0.0;
	blendKey = 0u;

	vec3 withinCell = fract(cellPosition) * float(rtgiLightCellSize);
	vec3 distanceToEdge = min(withinCell, float(rtgiLightCellSize) - withinCell);
	vec3 neighborWeight = 0.5 * (1.0 - smoothstep(vec3(0.0), vec3(rtgiLightCellOverlap), distanceToEdge));
	if (all(lessThanEqual(neighborWeight, vec3(0.0)))) {
		uvec4 record = texelFetch(texRtgiReceiverLights, cell, 0);
		confidence = rtgiLightListConfidence(record, cell, origin, flatNormal);
		return record & rtgiPackedLightMask;
	}

	ivec3 direction = 2 * ivec3(greaterThanEqual(withinCell, vec3(rtgiLightCellSize / 2))) - 1;
	ivec3 last = ivec3(greaterThan(neighborWeight, vec3(0.0)));
	// Traverse in world order so both sides of a boundary use the same mixture.
	ivec3 lower = cell + min(direction, ivec3(0)) * last;
	vec3 upperWeight = vec3(last) * mix(1.0 - neighborWeight, neighborWeight, greaterThan(direction, ivec3(0)));
	ivec3 worldOrigin = ivec3(floor(cameraPosition)) - ivec3(VoxelSize / 2u);
	ivec3 worldGridMin = worldOrigin + gridMin;
	uvec4 selected = uvec4(0u);
	float total = 0.0;
	uint listKey = 0u;
	int listCount = 0;
	for (int z = 0; z <= last.z; ++z) {
		for (int y = 0; y <= last.y; ++y) {
			for (int x = 0; x <= last.x; ++x) {
				ivec3 offset = ivec3(x, y, z);
				ivec3 neighbor = lower + offset;
				uvec4 record = texelFetch(texRtgiReceiverLights, neighbor, 0);
				vec3 weights = mix(1.0 - upperWeight, upperWeight, notEqual(offset, ivec3(0)));
				float weight = weights.x * weights.y * weights.z;
				float coveredWeight = weight * rtgiLightListConfidence(record, neighbor, origin, flatNormal);
				confidence += coveredWeight;
				if (useFallbackConfidence) weight = coveredWeight;
				if (weight <= 0.0) continue;
				record &= rtgiPackedLightMask;

				// Sample the overlapping lists as a mixture so each ray budget stays
				// at four. Conditioning the draw leaves it uniform for the next list.
				total += weight;
				float probability = weight / total;
				if (cellSample < probability) {
					selected = record;
					cellSample /= probability;
				} else {
					cellSample = (cellSample - probability) / max(1.0 - probability, 1e-6);
				}
				cellSample = min(cellSample, 0.99999994);
				listKey ^= rtgiEmitterKey(worldGridMin + neighbor * rtgiLightCellSize,
					rtgiLightListKey(record, worldOrigin));
				++listCount;
			}
		}
	}
	if (listCount > 1) blendKey = listKey | 1u;
	return selected;
}

vec3 rtgiEmitterOffset(uint id) {
	if (rtgiTorch(id)) return vec3(0.5, 0.625, 0.5);
	if (rtgiLantern(id)) return vec3(0.5, 0.375, 0.5);
	return vec3(0.5);
}

float rtgiEmitterRadius(uint id) {
	if (rtgiTorch(id)) return 0.085;
	if (rtgiLantern(id)) return 0.20;
	return rtgiSolidEmitter(id) ? 0.42 : 0.12;
}

// RGB is the sum of individually visible lights. Alpha controls the LPV fallback.
// A valid zero sum therefore differs from a light list that could miss a contributor.
vec4 rtgiLocalLighting(vec3 position, vec3 flatNormal, vec3 normal, vec2 disk, float cellSample,
	bool useFallbackConfidence, out uint lightKey) {
	lightKey = 0u;
	vec3 origin = position + flatNormal * rtgiRayBias;
	float coverage = rtgiLocalLightCoverage(origin);
	if (coverage <= 0.0) return vec4(0.0);

	float confidence;
	uint blendKey;
	uvec4 candidates = rtgiResolveLocalLights(origin, flatNormal, useFallbackConfidence, cellSample, confidence, blendKey);
	if (useFallbackConfidence && confidence <= 0.0) return vec4(0.0);

	vec3 direct = vec3(0.0);
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
		vec3 direction = delta / distanceToLight;
		float radius = rtgiEmitterRadius(id);
		if (dot(flatNormal, delta) < -radius) continue;
		ivec3 world = source - ivec3(VoxelSize / 2u) + ivec3(floor(cameraPosition));
		uint key = rtgiEmitterKey(world, id | (uint(packedLight >> 24u) << 16u));
		lightKey ^= key;

		if (any(notEqual(disk, vec2(0.0)))) {
			// Orient the virtual emitting disk toward the receiver. The endpoint
			// remains inside the source block for both lamps and solid emitters.
			vec3 axis = abs(direction.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			vec3 tangent = normalize(cross(axis, direction));
			vec3 bitangent = cross(direction, tangent);
			vec2 samplePoint = (key & 1u) == 0u ? disk : vec2(-disk.y, disk.x);
			delta += radius * (tangent * samplePoint.x + bitangent * samplePoint.y);
			distanceToLight = max(length(delta), 1e-4);
			direction = delta / distanceToLight;
		}

		float incidence = dot(normal, direction);
		if (incidence <= 0.0 || dot(flatNormal, direction) <= 0.0) continue;

		RtgiVoxelHit blocker;
		vec3 transmission;
		int visibility = rtgiTraceVoxels(origin, direction, distanceToLight, source, blocker, transmission);
		if (visibility == rtgiRayUnknown) return vec4(0.0);
		if (visibility == rtgiRayHit) continue;

		vec3 intensity = rtgiEmitterIntensity(texelFetch(texBlockData, int(id), 0).r);
		float falloff = 1.0 - distanceSquared / (range * range);
		// The finite source keeps the near field bounded and concentrates more
		// of the visible light around the lamp instead of filling the entire room.
		direct += intensity * transmission * (2.0 * incidence * falloff * falloff / (0.30 + distanceSquared));
	}
	if (blendKey != 0u) lightKey = blendKey;
	return vec4(direct, coverage * clamp(confidence, 0.0, 1.0));
}

vec4 rtgiLocalLighting(vec3 position, vec3 flatNormal, vec3 normal, bool useFallbackConfidence) {
	#ifdef ECLIPSE_RTGI_TRACE
		ivec3 seed = ivec3(floor(position)) - ivec3(VoxelSize / 2u) + ivec3(floor(cameraPosition));
	#else
		ivec3 seed = ivec3(ivec2(gl_FragCoord.xy), 0);
	#endif
	#ifdef ECLIPSE_RTGI_CACHE_UPDATE
		int sampleIndex = frameCounter / 8;
	#else
		int sampleIndex = frameCounter;
	#endif
	float phase = float(rtgiEmitterKey(seed, 0x9e3779b9u) >> 8u) * (1.0 / 16777216.0);
	float cellSample = fract(phase + 0.61803398875 * float(sampleIndex % 4096));
	uint unusedKey;
	return rtgiLocalLighting(position, flatNormal, normal, vec2(0.0), cellSample, useFallbackConfidence, unusedKey);
}

vec4 rtgiLocalLighting(vec3 position, vec3 flatNormal, vec3 normal) {
	return rtgiLocalLighting(position, flatNormal, normal, true);
}
