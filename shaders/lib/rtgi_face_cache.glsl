const uint rtgiFaceCacheSize = 65536u;
const uint rtgiFaceCacheLifetime = 80u;

struct RtgiFaceEntry {
	ivec4 key;
	uvec4 data;
};

// Update rays read the committed bank. A separate dispatch publishes the
// updated slots from the second bank after all the rays finish.
#if defined ECLIPSE_RTGI_CACHE_UPDATE || defined ECLIPSE_RTGI_CACHE_PUBLISH || defined ECLIPSE_RTGI_RESET
	layout(std430, binding = 7) coherent buffer RtgiFaceHistory {
		RtgiFaceEntry rtgiFaces[rtgiFaceCacheSize * 2u];
	};
#else
	layout(std430, binding = 7) readonly buffer RtgiFaceHistory {
		RtgiFaceEntry rtgiFaces[rtgiFaceCacheSize * 2u];
	};
#endif

#if !defined ECLIPSE_RTGI_RESET && !defined ECLIPSE_RTGI_CACHE_PUBLISH
ivec4 rtgiFaceKey(ivec3 voxel, vec3 normal, uint blockId) {
	int axis = rtgiLargestAxis(abs(normal));
	int face = 2 * axis + int(normal[axis] < 0.0);
	ivec3 world = voxel - ivec3(VoxelSize / 2u) + ivec3(floor(cameraPosition));
	return ivec4(world, int(blockId) * 6 + face);
}

uint rtgiFaceHash(ivec4 key) {
	uvec4 k = uvec4(key) * uvec4(0x8da6b343u, 0xd8163841u, 0xcb1ab31fu, 0x165667b1u);
	uint hash = k.x ^ k.y ^ k.z ^ k.w;
	hash = (hash ^ (hash >> 16u)) * 0x7feb352du;
	return hash ^ (hash >> 15u);
}

// RGB9E5 lets direct and indirect irradiance fit in the existing two words.
uint rtgiPackIrradiance(vec3 irradiance) {
	irradiance = clamp(irradiance, 0.0, 32.0);
	float peak = max(irradiance.r, max(irradiance.g, irradiance.b));
	int exponent;
	frexp(max(peak * (512.0 / 511.0), exp2(-16.0)), exponent);
	uvec3 mantissa = uvec3(round(irradiance * exp2(float(9 - exponent))));
	return mantissa.x | (mantissa.y << 9u) | (mantissa.z << 18u) | (uint(exponent + 15) << 27u);
}

vec3 rtgiUnpackIrradiance(uint encoded) {
	uvec3 mantissa = uvec3(encoded, encoded >> 9u, encoded >> 18u) & 511u;
	return vec3(mantissa) * exp2(float(encoded >> 27u) - 24.0);
}

bool rtgiLoadFace(ivec4 key, uint material, out vec3 direct, out vec3 indirect, out float freshness) {
	RtgiFaceEntry entry = rtgiFaces[rtgiFaceHash(key) & (rtgiFaceCacheSize - 1u)];
	uint age = uint(frameCounter) + 1u - entry.data.x;
	direct = vec3(0.0);
	indirect = vec3(0.0);
	freshness = 0.0;
	if (entry.data.x == 0u || age > rtgiFaceCacheLifetime || entry.data.w != material
		|| any(notEqual(entry.key, key))) return false;

	freshness = 1.0 - smoothstep(24.0, float(rtgiFaceCacheLifetime), float(age));
	indirect = rtgiUnpackIrradiance(entry.data.z) * freshness;
	if (age > 16u) return false;
	direct = rtgiUnpackIrradiance(entry.data.y);
	return true;
}
#endif
