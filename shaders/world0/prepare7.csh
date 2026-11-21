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
	float phi = raySample.y * 6.283185307;
	vec3 direction = sqrt(raySample.x) * (tangent * cos(phi) + bitangent * sin(phi)) + normal * sqrt(1.0 - raySample.x);

	vec3 direct = rtgiDirectIrradiance(point, normal);
	vec4 lighting;
	rtgiWorldBounce(point, normal, direction, rtgiVoxelSkylight(material), lighting);
	vec3 indirect = min(lighting.rgb, vec3(8.0));

	vec3 previousDirect;
	vec3 previousIndirect;
	float freshness;
	if (rtgiLoadFace(key, material, previousDirect, previousIndirect, freshness)) {
		direct = mix(previousDirect, direct, 0.50);
		indirect = mix(previousIndirect, indirect, 0.20);
	}

	rtgiFaces[pendingSlot].key = key;
	rtgiFaces[pendingSlot].data.y = rtgiPackIrradiance(direct);
	rtgiFaces[pendingSlot].data.z = rtgiPackIrradiance(indirect);
	rtgiFaces[pendingSlot].data.w = material;
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
