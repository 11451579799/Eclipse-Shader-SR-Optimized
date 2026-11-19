const uint rtgiFaceCacheSize = 65536u;
const uint rtgiFaceCacheLifetime = 24u;

struct RtgiFaceEntry {
	ivec4 key;
	uvec4 data;
};

// A compute pass reads the previous writes. Opaque shading publishes new entries
// afterwards, with one atomic claim per slot and frame.
#ifdef ECLIPSE_RTGI_TRACE
	layout(std430, binding = 7) readonly buffer RtgiFaceHistory {
		RtgiFaceEntry rtgiFaces[rtgiFaceCacheSize];
	};
#else
	layout(std430, binding = 7) coherent buffer RtgiFaceHistory {
		RtgiFaceEntry rtgiFaces[rtgiFaceCacheSize];
	};
#endif

#ifndef ECLIPSE_RTGI_RESET

ivec4 rtgiFaceKey(ivec3 voxel, vec3 normal, uint blockId) {
	int axis = rtgiLargestAxis(abs(normal));
	int face = 2 * axis + int(normal[axis] < 0.0);
	ivec3 world = voxel - ivec3(VoxelSize / 2u) + ivec3(floor(cameraPosition));
	return ivec4(world, int(blockId) * 6 + face);
}

uint rtgiFaceSlot(ivec4 key) {
	uvec4 k = uvec4(key) * uvec4(0x8da6b343u, 0xd8163841u, 0xcb1ab31fu, 0x165667b1u);
	uint hash = k.x ^ k.y ^ k.z ^ k.w;
	hash = (hash ^ (hash >> 16u)) * 0x7feb352du;
	return (hash ^ (hash >> 15u)) & (rtgiFaceCacheSize - 1u);
}

vec3 rtgiUnpackFaceBounce(uvec4 data) {
	return vec3(unpackHalf2x16(data.z).y, unpackHalf2x16(data.w));
}

bool rtgiLoadFace(ivec4 key, out vec3 albedo, out vec3 bounce) {
	RtgiFaceEntry entry = rtgiFaces[rtgiFaceSlot(key)];
	uint age = uint(frameCounter) + 1u - entry.data.x;
	if (entry.data.x == 0u || age > rtgiFaceCacheLifetime || any(notEqual(entry.key, key))) return false;
	albedo = vec3(unpackHalf2x16(entry.data.y), unpackHalf2x16(entry.data.z).x);
	bounce = rtgiUnpackFaceBounce(entry.data) * (1.0 - smoothstep(8.0, float(rtgiFaceCacheLifetime), float(age)));
	return true;
}

#ifndef ECLIPSE_RTGI_TRACE
void rtgiStoreFace(vec3 playerPosition, vec3 flatNormal, vec3 albedo, vec3 bounce) {
	ivec3 voxel = ivec3(floor(playerPosition + rtgiVoxelOffset() - flatNormal * rtgiRayBias));
	if (!rtgiVoxelContains(voxel)) return;
	uint blockId = imageLoad(imgVoxelMask, voxel).r;
	if (!rtgiFullVoxel(blockId)) return;

	ivec4 key = rtgiFaceKey(voxel, flatNormal, blockId);
	uint slot = rtgiFaceSlot(key);
	uint stamp = uint(frameCounter) + 1u;
	uint oldStamp = atomicExchange(rtgiFaces[slot].data.x, stamp);
	if (oldStamp == stamp) return;

	if (oldStamp != 0u && stamp - oldStamp <= rtgiFaceCacheLifetime && all(equal(rtgiFaces[slot].key, key))) {
		uvec4 oldData = rtgiFaces[slot].data;
		vec3 oldAlbedo = vec3(unpackHalf2x16(oldData.y), unpackHalf2x16(oldData.z).x);
		if (distance(oldAlbedo, albedo) < 0.3) {
			// Blend only the one-bounce estimate. The second bounce never feeds back.
			bounce = mix(rtgiUnpackFaceBounce(oldData), bounce, 0.20);
		}
	}

	rtgiFaces[slot].key = key;
	rtgiFaces[slot].data.y = packHalf2x16(albedo.rg);
	rtgiFaces[slot].data.z = packHalf2x16(vec2(albedo.b, bounce.r));
	rtgiFaces[slot].data.w = packHalf2x16(bounce.gb);
}
#endif

#endif
