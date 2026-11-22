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

bool rtgiTorch(uint id) {
	return id == BLOCK_TORCH || id == BLOCK_SOUL_TORCH || id == BLOCK_COPPER_TORCH || id == BLOCK_REDSTONE_TORCH_LIT;
}

bool rtgiLantern(uint id) {
	return id == BLOCK_LANTERN || id == BLOCK_SOUL_LANTERN || id == BLOCK_COPPER_LANTERN;
}

vec3 rtgiEmitterIntensity(uint packedEmission) {
	// The LPV table adds one block to the configured range. Recover the level
	// before converting it to intensity relative to a level-14 torch.
	float level = clamp((float(packedEmission >> 24u) - 1.0) / 14.0, 0.0, 1.0);
	vec3 color = toLinear(unpackUnorm4x8(packedEmission).rgb);
	return color * (1.5 * level * level);
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
	if (id >= 22u && id <= 37u) {
		// IDs follow block.properties, not binary connection order: N E S W.
		const uint connections[16] = uint[16](0u, 1u, 2u, 4u, 8u, 5u, 10u, 3u,
			9u, 6u, 12u, 11u, 7u, 14u, 13u, 15u);
		uint arms = connections[id - 22u];
		rtgiIntersectBox(origin, invDirection, parallel, vec3(0.375, 0.0, 0.375),
			vec3(0.625, 1.0, 0.625), nearest, hitAxis);
		// Two narrow rails with the same bounds as the vanilla fence model.
		for (int rail = 0; rail < 2; ++rail) {
			float y = rail == 0 ? 0.375 : 0.75;
			if ((arms & 1u) != 0u) rtgiIntersectBox(origin, invDirection, parallel, vec3(0.4375, y, 0.0), vec3(0.5625, y + 0.1875, 0.375), nearest, hitAxis);
			if ((arms & 2u) != 0u) rtgiIntersectBox(origin, invDirection, parallel, vec3(0.625, y, 0.4375), vec3(1.0, y + 0.1875, 0.5625), nearest, hitAxis);
			if ((arms & 4u) != 0u) rtgiIntersectBox(origin, invDirection, parallel, vec3(0.4375, y, 0.625), vec3(0.5625, y + 0.1875, 1.0), nearest, hitAxis);
			if ((arms & 8u) != 0u) rtgiIntersectBox(origin, invDirection, parallel, vec3(0.0, y, 0.4375), vec3(0.375, y + 0.1875, 0.5625), nearest, hitAxis);
		}
		return true;
	}
	if (id >= BLOCK_GATE_CLOSED_NS && id <= BLOCK_GATE_OPEN_EW) {
		bool ns = id == BLOCK_GATE_CLOSED_NS || id == BLOCK_GATE_OPEN_NS;
		bool open = id >= BLOCK_GATE_OPEN_NS;
		// A closed gate spans its opening; opening pivots each half to its edge.
		if (!open) {
			vec3 lo = ns ? vec3(0.0, 0.375, 0.375) : vec3(0.375, 0.375, 0.0);
			vec3 hi = ns ? vec3(1.0, 0.9375, 0.625) : vec3(0.625, 0.9375, 1.0);
			rtgiIntersectBox(origin, invDirection, parallel, lo, hi, nearest, hitAxis);
		} else {
			vec3 lo = vec3(0.0, 0.375, 0.0);
			vec3 hi = ns ? vec3(0.1875, 0.9375, 1.0) : vec3(1.0, 0.9375, 0.1875);
			rtgiIntersectBox(origin, invDirection, parallel, lo, hi, nearest, hitAxis);
			lo = ns ? vec3(0.8125, 0.375, 0.0) : vec3(0.0, 0.375, 0.8125);
			hi = vec3(1.0, 0.9375, 1.0);
			rtgiIntersectBox(origin, invDirection, parallel, lo, hi, nearest, hitAxis);
		}
		return true;
	}
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

	if (id >= BLOCK_IRON_DOOR_TOP_N && id <= BLOCK_IRON_DOOR_TOP_W) {
		uint side = id - BLOCK_IRON_DOOR_TOP_N;
		bool xWidth = side == 0u || side == 2u;
		vec3 lo = vec3(0.0);
		vec3 hi = vec3(1.0);
		const float thickness = 3.0 / 16.0;
		if (side == 0u) lo.z = 1.0 - thickness;
		if (side == 1u) hi.x = thickness;
		if (side == 2u) hi.z = thickness;
		if (side == 3u) lo.x = 1.0 - thickness;

		// The vanilla/SPBR top texture has two 4x3 alpha cutouts. Keep the
		// surrounding frame as six thin boxes so rays through the actual holes pass.
		for (int strip = 0; strip < 3; ++strip) {
			float u0 = strip == 0 ? 0.0 : (strip == 1 ? 7.0 / 16.0 : 13.0 / 16.0);
			float u1 = strip == 0 ? 3.0 / 16.0 : (strip == 1 ? 9.0 / 16.0 : 1.0);
			vec3 partLo = lo;
			vec3 partHi = hi;
			if (xWidth) { partLo.x = u0; partHi.x = u1; }
			else { partLo.z = u0; partHi.z = u1; }
			rtgiIntersectBox(origin, invDirection, parallel, partLo, partHi, nearest, hitAxis);
		}
		for (int band = 0; band < 3; ++band) {
			float y0 = band == 0 ? 0.0 : (band == 1 ? 8.0 / 16.0 : 13.0 / 16.0);
			float y1 = band == 0 ? 5.0 / 16.0 : (band == 1 ? 10.0 / 16.0 : 1.0);
			vec3 partLo = lo;
			vec3 partHi = hi;
			partLo.y = y0;
			partHi.y = y1;
			if (xWidth) { partLo.x = 3.0 / 16.0; partHi.x = 13.0 / 16.0; }
			else { partLo.z = 3.0 / 16.0; partHi.z = 13.0 / 16.0; }
			rtgiIntersectBox(origin, invDirection, parallel, partLo, partHi, nearest, hitAxis);
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

int rtgiTraceVoxels(vec3 origin, vec3 direction, float maxDistance, ivec3 lightVoxel, bool traceEmitterShapes,
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
				if (traceEmitterShapes && rtgiLantern(id)) {
					rtgiIntersectBox(origin - vec3(voxel), invDirection, parallel,
						vec3(0.3125, 0.0, 0.3125), vec3(0.6875, 0.5, 0.6875), nearest, hitAxis);
				} else if (traceEmitterShapes && rtgiTorch(id)) {
					rtgiIntersectBox(origin - vec3(voxel), invDirection, parallel,
						vec3(0.4375, 0.0, 0.4375), vec3(0.5625, 0.625, 0.5625), nearest, hitAxis);
				} else if (stepIndex > 0 && rtgiFullVoxel(id)) {
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

int rtgiTraceVoxels(vec3 origin, vec3 direction, float maxDistance, ivec3 lightVoxel,
	out RtgiVoxelHit hit, out vec3 transmission) {
	return rtgiTraceVoxels(origin, direction, maxDistance, lightVoxel, false, hit, transmission);
}
