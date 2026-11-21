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
vec2 rtgiGuideSign(vec2 v) { return vec2(v.x < 0.0 ? -1.0 : 1.0, v.y < 0.0 ? -1.0 : 1.0); }
uint rtgiPackGuide(vec3 direction, float score) {
	vec3 oct = direction / (abs(direction.x) + abs(direction.y) + abs(direction.z));
	if (oct.z < 0.0) oct.xy = (1.0 - abs(oct.yx)) * rtgiGuideSign(oct.xy);
	return (packSnorm4x8(vec4(oct.xy, 0.0, 0.0)) & 65535u) | (packHalf2x16(vec2(0.0, clamp(score, 0.0, 65504.0))) & 0xffff0000u);
}
vec3 rtgiUnpackGuide(uint guide) {
	vec2 xy = unpackSnorm4x8(guide & 65535u).xy;
	vec3 direction = vec3(xy, 1.0 - abs(xy.x) - abs(xy.y));
	if (direction.z < 0.0) direction.xy = (1.0 - abs(direction.yx)) * rtgiGuideSign(direction.xy);
	return normalize(direction);
}
uint rtgiGuideRandom(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	return value ^ (value >> 16u);
}

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
	bool sameFace = previous.data.x != 0u && previous.data.w == material && all(equal(previous.key, key));
	float skylight = rtgiVoxelSkylight(material);
	bool darkFace = skylight < 0.75;
	bool validGuide = darkFace && sameFace && age <= 16u;
	uint packedGuide = validGuide ? rtgiFaceGuides[slot] : 0u;
	float oldScore = validGuide ? unpackHalf2x16(packedGuide).y : 0.0;
	validGuide = validGuide && oldScore > 0.0001;
	vec3 guideDirection = validGuide ? rtgiUnpackGuide(packedGuide) : normal;
	float phi = raySample.y * 6.283185307;
	vec3 direction = sqrt(raySample.x) * (tangent * cos(phi) + bitangent * sin(phi)) + normal * sqrt(1.0 - raySample.x);
	float sampleWeight = 1.0;
	if (validGuide) {
		// The mixture decision uses a hash independent of the continuous sample.
		float chooseGuide = float(rtgiGuideRandom(hash ^ uint(frameCounter / 8) ^ 0xa511e9b3u) & 0x00ffffffu) * (1.0 / 16777216.0);
		if (chooseGuide < 0.25) {
			vec3 rayTangent = normalize(cross(abs(guideDirection.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), guideDirection));
			vec3 rayBitangent = cross(guideDirection, rayTangent);
			direction = sqrt(raySample.x) * (rayTangent * cos(phi) + rayBitangent * sin(phi)) + guideDirection * sqrt(1.0 - raySample.x);
		}
		float cosine = max(dot(normal, direction), 0.0);
		float mixture = 0.75 * cosine + 0.25 * max(dot(guideDirection, direction), 0.0);
		sampleWeight = mixture > 0.0 ? cosine / mixture : 0.0;
	}
	float normalCosine = max(dot(normal, direction), 0.0);

	vec3 direct = rtgiDirectIrradiance(point, normal);
	vec4 lighting;
	// Directions outside the geometric hemisphere contribute zero; all others
	// trace anew, including those selected using the previous guide.
	lighting = vec4(0.0);
	if (normalCosine > 0.0)
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
