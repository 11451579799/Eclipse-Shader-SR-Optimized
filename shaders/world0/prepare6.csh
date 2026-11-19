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

uvec4 rtgiGatherCellLights(ivec3 cell) {
	vec3 cellMin = vec3(cell * rtgiLightCellSize + rtgiLightGridMin());
	vec3 cellMax = cellMin + float(rtgiLightCellSize);
	vec3 camera = fract(cameraPosition) + float(VoxelSize / 2u);
	vec3 cameraGap = rtgiCellGap(camera, cellMin, cellMax);
	if (dot(cameraGap, cameraGap) >= rtgiLightCoverageRadius * rtgiLightCoverageRadius) return uvec4(0u);

	uvec4 candidates = uvec4(0u);
	int count = 0;
	ivec3 first = max(cell - 2, ivec3(0));
	ivec3 last = min(cell + 2, ivec3(rtgiLightGridCells - 1));
	for (int z = first.z; z <= last.z; ++z) {
		for (int y = first.y; y <= last.y; ++y) {
			for (int x = first.x; x <= last.x; ++x) {
				ivec3 sourceCell = ivec3(x, y, z);
				uvec4 entries = imageLoad(rtgiEmitterCells, sourceCell);
				if (entries.x == 0u) continue;
				if (entries.x == rtgiIncompleteLights) return uvec4(rtgiIncompleteLights);

				ivec3 base = ivec3(cellMin) + (sourceCell - cell) * rtgiLightCellSize;
				for (int i = 0; i < 8; ++i) {
					uint entry = (entries[i / 2] >> ((i % 2) * 14)) & 0x3fffu;
					if (entry == 0u) break;
					ivec3 source = base + ivec3(entry & 7u, (entry >> 3u) & 7u, (entry >> 6u) & 7u);
					uint range = entry >> 9u;
					// Measure from the source voxel bounds, including emitters off center.
					vec3 gap = rtgiCellGap(vec3(source), cellMin - 1.0, cellMax);
					float limit = min(float(range), rtgiLightRange);
					if (dot(gap, gap) >= limit * limit) continue;
					if (range == rtgiUntrackedRange || count == 4) return uvec4(rtgiIncompleteLights);
					candidates[count++] = uint(source.x) | (uint(source.y) << 8u) | (uint(source.z) << 16u) | (range << 24u);
				}
			}
		}
	}
	return candidates;
}

void main() {
	ivec3 cell = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(cell, ivec3(rtgiLightGridCells)))) return;
	imageStore(rtgiReceiverLights, cell, rtgiGatherCellLights(cell));
}

#else
layout(local_size_x = 1) in;
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
