#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"

#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
layout(rgba32ui) uniform readonly uimage3D rtgiEmitterCells;
layout(rgba32ui) uniform writeonly uimage3D rtgiReceiverLights;
uniform vec3 cameraPosition;

#include "/lib/voxel_common.glsl"
#include "/lib/rtgi_light_grid.glsl"

#if LPV_SIZE == 6
	const ivec3 workGroups = ivec3(3, 3, 3);
#else
	const ivec3 workGroups = ivec3(5, 5, 5);
#endif

struct RtgiCellLights {
	uvec4 known;
	uvec4 bounds[4];
};

bool rtgiWeakerLight(float firstRank, uint first, float secondRank, uint second) {
	return firstRank > secondRank || (firstRank == secondRank && first > second);
}

void rtgiIncludeUnresolved(inout RtgiCellLights lights, ivec3 lo, ivec3 hi, uint range, vec3 center) {
	// Keep groups on opposite sides separate. One enclosing box could falsely
	// cover an entire room between independent light banks.
	ivec3 side = ivec3(greaterThanEqual(vec3(lo + hi + 1) * 0.5, center));
	int octant = side.x + 2 * side.y + 4 * side.z;
	int slot = (octant % 2) * 2;
	uvec4 pair = lights.bounds[octant / 2];
	if (pair[slot] != 0u) {
		lo = min(lo, rtgiUnpackLightPosition(pair[slot]));
		hi = max(hi, rtgiUnpackLightPosition(pair[slot + 1]));
		range = max(range, pair[slot] >> 24u);
	}

	pair[slot] = rtgiPackLightPosition(lo) | (range << 24u);
	pair[slot + 1] = rtgiPackLightPosition(hi);
	lights.bounds[octant / 2] = pair;
}

RtgiCellLights rtgiGatherCellLights(ivec3 cell) {
	RtgiCellLights lights = RtgiCellLights(uvec4(0u), uvec4[4](uvec4(0u), uvec4(0u), uvec4(0u), uvec4(0u)));
	vec3 cellMin = vec3(cell * rtgiLightCellSize + rtgiLightGridMin());
	vec3 cellMax = cellMin + float(rtgiLightCellSize);
	// Shading can reuse this list on either side of the cell boundary.
	vec3 receiverMin = cellMin - rtgiLightCellOverlap;
	vec3 receiverMax = cellMax + rtgiLightCellOverlap;
	vec3 center = (cellMin + cellMax) * 0.5;
	vec3 camera = fract(cameraPosition) + float(VoxelSize / 2u);
	vec3 cameraGap = rtgiCellGap(camera, receiverMin, receiverMax);
	if (dot(cameraGap, cameraGap) >= rtgiLightCoverageRadius * rtgiLightCoverageRadius) return lights;

	vec4 ranks = vec4(0.0);
	int count = 0;
	const float maxReach = rtgiLightRange + rtgiLightFallbackFade;
	ivec3 first = max(cell - 3, ivec3(0));
	ivec3 last = min(cell + 3, ivec3(rtgiLightGridCells - 1));
	for (int z = first.z; z <= last.z; ++z) {
		for (int y = first.y; y <= last.y; ++y) {
			for (int x = first.x; x <= last.x; ++x) {
				ivec3 sourceCell = ivec3(x, y, z);
				ivec3 base = ivec3(cellMin) + (sourceCell - cell) * rtgiLightCellSize;
				vec3 cellGap = rtgiBoxGap(receiverMin, receiverMax, vec3(base), vec3(base + rtgiLightCellSize));
				if (dot(cellGap, cellGap) >= maxReach * maxReach) continue;

				uvec4 entries = imageLoad(rtgiEmitterCells, sourceCell);
				if (entries.x == 0u) continue;
				if ((entries.x & rtgiLightRecordFlag) != 0u) {
					uvec4 untracked = imageLoad(rtgiEmitterCells, sourceCell + ivec3(0, 0, rtgiLightGridCells));
					ivec3 lo = base + rtgiUnpackLightPosition(untracked.x);
					ivec3 hi = base + rtgiUnpackLightPosition(untracked.y);
					vec3 gap = rtgiBoxGap(receiverMin, receiverMax, vec3(lo), vec3(hi + 1));
					uint range = untracked.x >> 24u;
					float reach = float(range) + rtgiLightFallbackFade;
					if (dot(gap, gap) < reach * reach) rtgiIncludeUnresolved(lights, lo, hi, range, center);
				}

				for (int i = 0; i < 8; ++i) {
					uint entry = (entries[i / 2] >> ((i % 2) * 15)) & 0x7fffu;
					if (entry == 0u) break;
					ivec3 source = base + rtgiEmitterVoxelOffset(entry);
					uint range = (entry >> 9u) & 31u;
					float reach = float(range) + rtgiLightFallbackFade;
					vec3 gap = rtgiBoxGap(receiverMin, receiverMax, vec3(source), vec3(source + 1));
					if (dot(gap, gap) >= reach * reach) continue;

					uint packedLight = rtgiPackLightPosition(source) | (range << 24u);
					vec3 delta = vec3(source) + 0.5 - center;
					float rank = (dot(gap, gap) + 0.0625 * dot(delta, delta)) / float(range * range);
					if (count < 4) {
						ranks[count] = rank;
						lights.known[count++] = packedLight;
						continue;
					}

					int firstPair = rtgiWeakerLight(ranks.x, lights.known.x, ranks.y, lights.known.y) ? 0 : 1;
					int secondPair = rtgiWeakerLight(ranks.z, lights.known.z, ranks.w, lights.known.w) ? 2 : 3;
					int weakest = rtgiWeakerLight(ranks[firstPair], lights.known[firstPair], ranks[secondPair], lights.known[secondPair])
						? firstPair : secondPair;
					if (rtgiWeakerLight(ranks[weakest], lights.known[weakest], rank, packedLight)) {
						ranks[weakest] = rank;
						lights.known[weakest] = packedLight;
					}
				}
			}
		}
	}
	return lights;
}

void main() {
	ivec3 cell = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(cell, ivec3(rtgiLightGridCells)))) return;
	RtgiCellLights lights = rtgiGatherCellLights(cell);
	uvec4 packedBounds = uvec4(0u);
	uint boundCount = 0u;
	for (int i = 0; i < 8; ++i) {
		int fromSlot = (i % 2) * 2;
		uvec4 pair = lights.bounds[i / 2];
		if (pair[fromSlot] == 0u) continue;
		int toSlot = int(boundCount & 1u) * 2;
		packedBounds[toSlot] = pair[fromSlot];
		packedBounds[toSlot + 1] = pair[fromSlot + 1];
		if (toSlot == 2) {
			imageStore(rtgiReceiverLights, cell + ivec3(0, 0, (1 + int(boundCount / 2u)) * rtgiLightGridCells), packedBounds);
			packedBounds = uvec4(0u);
		}
		++boundCount;
	}
	if ((boundCount & 1u) != 0u) {
		imageStore(rtgiReceiverLights, cell + ivec3(0, 0, (1 + int(boundCount / 2u)) * rtgiLightGridCells), packedBounds);
	}
	if (boundCount != 0u) {
		lights.known.x |= rtgiLightRecordFlag;
		lights.known.w |= (boundCount - 1u) << 29u;
	}
	imageStore(rtgiReceiverLights, cell, lights.known);
}

#else
layout(local_size_x = 1) in;
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
