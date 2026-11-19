// Camera-relative voxels preserve sub-block precision far from world origin.
#include "/lib/voxel_common.glsl"

const int rtgiRayMiss = 0;
const int rtgiRayHit = 1;
const int rtgiRayUnknown = 2;
const float rtgiRayBias = 0.012;

struct RtgiVoxelHit {
	ivec3 voxel;
	uint blockId;
	vec3 normal;
	float distance;
};

vec3 rtgiVoxelOffset() {
	return fract(cameraPosition) + float(VoxelSize / 2u);
}

bool rtgiVoxelContains(ivec3 voxel) {
	return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, ivec3(VoxelSize)));
}

bool rtgiSolidEmitter(uint id) {
	return id == BLOCK_GLOWSTONE || id == BLOCK_JACK_O_LANTERN || id == BLOCK_SEA_LANTERN
		|| id == BLOCK_SHROOMLIGHT || (id >= BLOCK_FROGLIGHT_OCHRE && id <= BLOCK_FROGLIGHT_VERDANT)
		|| (id >= BLOCK_COPPER_BULB_LIT && id <= BLOCK_COPPER_BULB_WEATHERED_LIT)
		|| (id >= BLOCK_LAMP_LIT_BLACK && id <= BLOCK_LAMP_LIT_YELLOW);
}

bool rtgiFullVoxel(uint id) {
	return id == 1u || (id > 0u && id < 2000u
		&& ((texelFetch(texBlockData, int(id), 0).g & 0x00ffffffu) == 0u || rtgiSolidEmitter(id)));
}

int rtgiLargestAxis(vec3 v) {
	return v.x >= max(v.y, v.z) ? 0 : (v.y >= v.z ? 1 : 2);
}

void rtgiIntersectBox(vec3 origin, vec3 invDirection, bvec3 parallel, vec3 lo, vec3 hi,
	inout float nearest, inout int hitAxis) {
	if (any(bvec3(parallel.x && (origin.x <= lo.x || origin.x >= hi.x),
		parallel.y && (origin.y <= lo.y || origin.y >= hi.y),
		parallel.z && (origin.z <= lo.z || origin.z >= hi.z)))) return;

	vec3 a = (lo - origin) * invDirection;
	vec3 b = (hi - origin) * invDirection;
	vec3 enter = mix(min(a, b), vec3(-1e6), parallel);
	vec3 leave = mix(max(a, b), vec3(1e6), parallel);
	int axis = rtgiLargestAxis(enter);
	float t = enter[axis];
	if (t < -1e-5 || t >= nearest || min(leave.x, min(leave.y, leave.z)) <= t + 1e-5) return;
	nearest = max(t, 0.0);
	hitAxis = axis;
}

bool rtgiPartialShape(uint id, vec3 origin, vec3 invDirection, bvec3 parallel,
	inout float nearest, inout int hitAxis) {
	if (id >= BLOCK_STAIRS_BOTTOM_N && id <= BLOCK_STAIRS_TOP_OUTER_S_W) {
		// The second layer of each stair is the union of up to four half-block columns.
		const uint quadrants[12] = uint[12](3u, 10u, 12u, 5u, 14u, 13u, 7u, 11u, 1u, 2u, 8u, 4u);
		uint shape = (id - BLOCK_STAIRS_BOTTOM_N) % 12u;
		float baseY = id >= BLOCK_STAIRS_TOP_N ? 0.5 : 0.0;
		rtgiIntersectBox(origin, invDirection, parallel, vec3(0.0, baseY, 0.0),
			vec3(1.0, baseY + 0.5, 1.0), nearest, hitAxis);
		float stepY = 0.5 - baseY;
		for (uint i = 0u; i < 4u; ++i) {
			if ((quadrants[shape] & (1u << i)) == 0u) continue;
			vec3 lo = vec3(float(i & 1u) * 0.5, stepY, float(i >> 1u) * 0.5);
			rtgiIntersectBox(origin, invDirection, parallel, lo, lo + 0.5, nearest, hitAxis);
		}
		return true;
	}

	vec3 lo = vec3(0.0);
	vec3 hi = vec3(1.0);
	const float thickness = 3.0 / 16.0;
	if (id == BLOCK_SLAB_TOP) {
		lo.y = 0.5;
	} else if (id == BLOCK_SLAB_BOTTOM) {
		hi.y = 0.5;
	} else if (id == BLOCK_TRAPDOOR_TOP) {
		lo.y = 1.0 - thickness;
	} else if (id == BLOCK_TRAPDOOR_BOTTOM) {
		hi.y = thickness;
	} else {
		uint side;
		if (id >= BLOCK_DOOR_N && id <= BLOCK_DOOR_W) side = id - BLOCK_DOOR_N;
		else if (id >= BLOCK_TRAPDOOR_N && id <= BLOCK_TRAPDOOR_W) side = id - BLOCK_TRAPDOOR_N;
		else return false;

		if (side == 0u) lo.z = 1.0 - thickness;
		if (side == 1u) hi.x = thickness;
		if (side == 2u) hi.z = thickness;
		if (side == 3u) lo.x = 1.0 - thickness;
	}
	rtgiIntersectBox(origin, invDirection, parallel, lo, hi, nearest, hitAxis);
	return true;
}

int rtgiTraceVoxels(vec3 origin, vec3 direction, float maxDistance, ivec3 lightVoxel,
	out RtgiVoxelHit hit, out vec3 transmission) {
	ivec3 voxel = ivec3(floor(origin));
	vec3 directionSign = sign(direction);
	bvec3 parallel = lessThan(abs(direction), vec3(1e-6));
	vec3 stride = 1.0 / max(abs(direction), vec3(1e-6));
	vec3 invDirection = stride * directionSign;
	vec3 withinVoxel = fract(origin);
	vec3 crossing = mix(withinVoxel, 1.0 - withinVoxel, greaterThan(direction, vec3(0.0))) * stride;
	crossing = mix(crossing, vec3(1e6), parallel);
	float entry = 0.0;
	int entryAxis = 0;
	transmission = vec3(1.0);

	// The longest 16-block shadow ray crosses at most 29 grid planes.
	for (int stepIndex = 0; stepIndex < 32; ++stepIndex) {
		if (!rtgiVoxelContains(voxel)) return rtgiRayUnknown;
		if (voxel == lightVoxel) return rtgiRayMiss;

		uint id = imageLoad(imgVoxelMask, voxel).r;
		if (id > 0u && id < 2000u) {
			int hitAxis = -1;
			float nearest = maxDistance;
			if (!rtgiPartialShape(id, origin - vec3(voxel), invDirection, parallel, nearest, hitAxis)) {
				if (stepIndex > 0 && rtgiFullVoxel(id)) {
					nearest = entry;
					hitAxis = entryAxis;
				} else if (stepIndex > 0 && id > BLOCK_GLASS && id <= BLOCK_GLASS_YELLOW) {
					transmission *= toLinear(unpackUnorm4x8(texelFetch(texBlockData, int(id), 0).g).rgb);
				}
			}
			if (hitAxis >= 0) {
				hit.voxel = voxel;
				hit.blockId = id;
				hit.normal = vec3(0.0);
				hit.normal[hitAxis] = -directionSign[hitAxis];
				hit.distance = nearest;
				return rtgiRayHit;
			}
		}

		entry = min(crossing.x, min(crossing.y, crossing.z));
		if (entry >= maxDistance - 1e-5) return rtgiRayMiss;
		vec3 crossed = step(crossing, vec3(entry + 1e-5));
		entryAxis = rtgiLargestAxis(crossed * abs(direction));
		voxel += ivec3(crossed * directionSign);
		crossing += crossed * stride;
	}
	return rtgiRayUnknown;
}
