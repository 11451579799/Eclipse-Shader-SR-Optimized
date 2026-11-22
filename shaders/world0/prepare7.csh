#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

#ifdef ECLIPSE_RTGI_WORLD
const ivec3 workGroups = ivec3(6, 6, 6);
uniform vec3 cameraPosition;
uniform int frameCounter;
uniform float rainStrength;

#define ECLIPSE_RTGI_TRACE
#define ECLIPSE_RTGI_CACHE_UPDATE
#include "/lib/rtgi_world.glsl"

// Octahedral direction in the low word; the high word is a half-float score.
uint rtgiPackGuide(vec3 direction, float score) {
	vec3 oct = direction / (abs(direction.x) + abs(direction.y) + abs(direction.z));
	if (oct.z < 0.0) oct.xy = (1.0 - abs(oct.yx)) * rtgiGuideSign(oct.xy);
	return (packSnorm4x8(vec4(oct.xy, 0.0, 0.0)) & 65535u) | (packHalf2x16(vec2(0.0, clamp(score, 0.0, 65504.0))) & 0xffff0000u);
}
uint rtgiGuideRandom(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	return value ^ (value >> 16u);
}

#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
layout(rgba32ui) uniform readonly uimage3D rtgiEmitterCells;

bool rtgiFindPortal(vec3 point, vec3 normal, out ivec3 door, out uint side) {
	ivec3 gridMin = rtgiLightGridMin();
	vec3 grid = (point - vec3(gridMin)) / float(rtgiLightCellSize);
	ivec3 base = ivec3(floor(grid));
	ivec3 stepCell = 2 * ivec3(step(vec3(0.5), fract(grid))) - 1;
	float best = 64.0;
	bool found = false;
	for (int i = 0; i < 8; ++i) {
		ivec3 cell = base + ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1) * stepCell;
		if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(rtgiLightGridCells)))) continue;
		uint entry = imageLoad(rtgiEmitterCells, cell + ivec3(0, 0, rtgiLightGridCells)).z;
		if (entry == 0u || entry > 512u) continue;
		ivec3 candidate = gridMin + cell * rtgiLightCellSize + rtgiEmitterVoxelOffset(entry - 1u);
		if (!rtgiVoxelContains(candidate)) continue;
		uint id = imageLoad(imgVoxelMask, candidate).r;
		if (id < BLOCK_IRON_DOOR_TOP_N || id > BLOCK_IRON_DOOR_TOP_W) continue;
		uint axis = id - BLOCK_IRON_DOOR_TOP_N;
		vec3 center = vec3(candidate) + 0.5;
		if (axis == 0u) center.z = float(candidate.z) + 0.90625;
		if (axis == 1u) center.x = float(candidate.x) + 0.09375;
		if (axis == 2u) center.z = float(candidate.z) + 0.09375;
		if (axis == 3u) center.x = float(candidate.x) + 0.90625;
		vec3 delta = center - point;
		float distanceSquared = dot(delta, delta);
		if (distanceSquared >= best || distanceSquared < 0.04 || dot(delta, normal) <= 0.0) continue;
		best = distanceSquared;
		door = candidate;
		side = axis;
		found = true;
	}
	return found;
}

#include "/lib/rtgi_portals.glsl"

#endif

void rtgiUpdateFace(ivec3 voxel, uint blockId, vec3 normal) {
	uint material = rtgiVoxelMaterialAt(voxel, normal);
	if (material == 0u) return;

	ivec3 neighbor = voxel + ivec3(normal);
	if (!rtgiVoxelContains(neighbor) || rtgiFullVoxel(imageLoad(imgVoxelMask, neighbor).r)) return;

	ivec4 key = rtgiFaceKey(voxel, normal, blockId);
	uint hash = rtgiFaceHash(key);
	uint pendingSlot = rtgiFaceCacheSize + (hash & (rtgiFaceCacheSize - 1u));
	uint stamp = uint(frameCounter) + 1u;
	if (atomicExchange(rtgiFaces[pendingSlot].data.x, stamp) == stamp) return;

	// Refresh one eighth of the voxel grid per frame, even off camera.
	// Decorrelate the ray direction from the position on the face.
	vec2 phase = vec2(hash & 65535u, hash >> 16u) * (1.0 / 65536.0);
	float sampleIndex = float((frameCounter / 8) % 4096);
	vec2 raySample = fract(phase + vec2(0.75487767, 0.56984029) * sampleIndex);
	vec2 faceSample = fract(phase.yx + vec2(0.81917251, 0.67104361) * sampleIndex) - 0.5;
	vec3 tangent = abs(normal.y) > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
	vec3 bitangent = cross(normal, tangent);
	vec3 center = vec3(voxel) + 0.5 + 0.5 * normal;
	vec3 point = center + 0.9 * (tangent * faceSample.x + bitangent * faceSample.y);
	uint slot = hash & (rtgiFaceCacheSize - 1u);
	RtgiFaceEntry previous = rtgiFaces[slot];
	uint age = stamp - previous.data.x;
	bool sameFace = previous.data.x != 0u && previous.data.w == material && rtgiFaceMatches(previous.key, key);
	float skylight = rtgiVoxelSkylight(material);
	bool darkFace = skylight < 0.75;
	bool validGuide = darkFace && sameFace && age <= 16u;
	uint packedGuide = validGuide ? rtgiFaceGuides[slot] : 0u;
	float oldScore = validGuide ? unpackHalf2x16(packedGuide).y : 0.0;
	validGuide = validGuide && oldScore > 0.0001;
	vec3 guideDirection = validGuide ? rtgiUnpackGuide(packedGuide) : normal;
	float phi = raySample.y * 6.283185307;
	vec3 direction = sqrt(raySample.x) * (tangent * cos(phi) + bitangent * sin(phi)) + normal * sqrt(1.0 - raySample.x);
	float guideProbability = validGuide ? 0.25 : 0.0;
	float portalProbability = 0.0;
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		ivec3 door = ivec3(0);
		uint doorSide = 0u;
		vec3 rayOrigin = point + normal * rtgiRayBias;
		if (darkFace && rtgiFindPortal(rayOrigin, normal, door, doorSide)) portalProbability = 0.20;
	#endif
	float baseProbability = 1.0 - guideProbability - portalProbability;
	float select = float(rtgiGuideRandom(hash ^ uint(frameCounter / 8) ^ 0xa511e9b3u) & 0x00ffffffu) * (1.0 / 16777216.0);
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		if (select < portalProbability) direction = normalize(rtgiPortalPoint(door, doorSide, raySample) - rayOrigin);
		else
	#endif
	if (select < portalProbability + guideProbability) {
		vec3 rayTangent = normalize(cross(abs(guideDirection.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), guideDirection));
		vec3 rayBitangent = cross(guideDirection, rayTangent);
		direction = sqrt(raySample.x) * (rayTangent * cos(phi) + rayBitangent * sin(phi)) + guideDirection * sqrt(1.0 - raySample.x);
	}
	float cosine = max(dot(normal, direction), 0.0);
	float mixture = baseProbability * cosine + guideProbability * max(dot(guideDirection, direction), 0.0);
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		if (portalProbability > 0.0) mixture += portalProbability * rtgiPortalPdf(rayOrigin, direction, door, doorSide);
	#endif
	float sampleWeight = mixture > 0.0 ? cosine / mixture : 0.0;
	vec3 direct = rtgiDirectIrradiance(point, normal);
	vec4 lighting;
	// Directions outside the geometric hemisphere contribute zero; all others
	// trace anew, including those selected using the previous guide.
	lighting = vec4(0.0);
	if (cosine > 0.0)
		rtgiWorldBounce(point, normal, direction, skylight, lighting);
	vec3 indirect = min(lighting.rgb, vec3(8.0)) * sampleWeight;
	float score = max(lighting.r, max(lighting.g, lighting.b));
	float decayedScore = oldScore * 0.8;
	uint nextGuide = 0u;
	if (darkFace)
		nextGuide = score > decayedScore ? rtgiPackGuide(direction, score)
			: rtgiPackGuide(guideDirection, decayedScore);

	if (sameFace && age <= rtgiFaceCacheLifetime) {
		float freshness = 1.0 - smoothstep(24.0, float(rtgiFaceCacheLifetime), float(age));
		if (age <= 16u)
			direct = mix(rtgiUnpackIrradiance(previous.data.y), direct, 0.50);
		if (freshness > 0.0)
			indirect = mix(rtgiUnpackIrradiance(previous.data.z) * freshness, indirect, 0.20);
	}

	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		if (portalProbability > 0.0) key.w = int(uint(key.w) | rtgiEncodePortal(door - voxel, doorSide));
	#endif
	rtgiFaces[pendingSlot].key = key;
	rtgiFaces[pendingSlot].data.y = rtgiPackIrradiance(direct);
	rtgiFaces[pendingSlot].data.z = rtgiPackIrradiance(indirect);
	rtgiFaces[pendingSlot].data.w = material;
	rtgiFaceGuides[pendingSlot] = nextGuide;
}

void main() {
	const int radius = 24;
	int phase = frameCounter & 7;
	ivec3 offset = ivec3(phase & 1, (phase >> 1) & 1, phase >> 2);
	ivec3 alignment = ivec3(floor(cameraPosition)) & 1;
	ivec3 voxel = ivec3(gl_GlobalInvocationID) * 2 + offset
		+ ivec3(int(VoxelSize) / 2 - radius) - alignment;
	vec3 position = vec3(voxel) + 0.5 - rtgiVoxelOffset();
	if (dot(position, position) > float(radius * radius)) return;

	uint blockId = imageLoad(imgVoxelMask, voxel).r;
	if (!rtgiFullVoxel(blockId)) return;
	for (int axis = 0; axis < 3; ++axis) {
		vec3 normal = vec3(0.0);
		normal[axis] = 1.0;
		rtgiUpdateFace(voxel, blockId, normal);
		rtgiUpdateFace(voxel, blockId, -normal);
	}
}
#else
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
