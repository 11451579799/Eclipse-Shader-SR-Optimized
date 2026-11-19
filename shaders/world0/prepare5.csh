#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"

#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS

layout(local_size_x = 8, local_size_y = 8, local_size_z = 4) in;
layout(rgba32ui) uniform writeonly uimage3D rtgiEmitterCells;
uniform vec3 cameraPosition;
uniform usampler1D texBlockData;

#include "/lib/voxel_common.glsl"
#include "/lib/rtgi_light_grid.glsl"

#if LPV_SIZE == 6
	const ivec3 workGroups = ivec3(9, 9, 9);
#else
	const ivec3 workGroups = ivec3(17, 17, 17);
#endif
shared uint emitterCount;
shared uint emitterEntries[8];
shared uint emitterAxes;
shared uint emitterRange;

void main() {
	ivec3 cell = ivec3(gl_WorkGroupID);
	ivec3 base = cell * rtgiLightCellSize + rtgiLightGridMin();
	vec3 camera = fract(cameraPosition) + float(VoxelSize / 2u);
	vec3 gap = rtgiCellGap(camera, vec3(base), vec3(base + rtgiLightCellSize));
	float radius = rtgiLightCoverageRadius + rtgiLightRange + rtgiLightFallbackFade;
	if (dot(gap, gap) >= radius * radius) {
		if (gl_LocalInvocationIndex == 0u) imageStore(rtgiEmitterCells, cell, uvec4(0u));
		return;
	}

	if (gl_LocalInvocationIndex == 0u) {
		emitterCount = 0u;
		emitterAxes = 0u;
		emitterRange = 0u;
	}
	if (gl_LocalInvocationIndex < 8u) emitterEntries[gl_LocalInvocationIndex] = 0u;
	barrier();

	uint localAxes = 0u;
	uint localRange = 0u;
	for (uint layer = 0u; layer < 2u; ++layer) {
		uint index = gl_LocalInvocationIndex + 256u * layer;
		ivec3 offset = rtgiEmitterVoxelOffset(index);
		ivec3 voxel = base + offset;
		if (any(lessThan(voxel, ivec3(0))) || any(greaterThanEqual(voxel, ivec3(VoxelSize)))) continue;
		uint rawId = imageLoad(imgVoxelMask, voxel).r;
		if (rawId == 0u || rawId == 1u) continue;
		uint range = rawId >= 50000u ? uint(rtgiLightRange) : texelFetch(texBlockData, int(rawId % 2000u), 0).r >> 24u;
		if (range == 0u) continue;
		uint untracked = rawId >= 2000u || range > uint(rtgiLightRange) ? rtgiUntrackedEmitter : 0u;
		range = min(range, uint(rtgiLightRange));
		uint slot = atomicAdd(emitterCount, 1u);
		if (slot < 8u) emitterEntries[slot] = index | (range << 9u) | untracked;
		localAxes |= (1u << uint(offset.x)) | (1u << uint(8 + offset.y)) | (1u << uint(16 + offset.z));
		localRange = max(localRange, range);
	}
	barrier();

	// Keep the occupied bounds of a dense cell so distant receivers can still cull it.
	if (emitterCount > 8u) {
		if (localAxes != 0u) {
			atomicOr(emitterAxes, localAxes);
			atomicMax(emitterRange, localRange);
		}
		barrier();
		if (gl_LocalInvocationIndex == 0u) {
			uvec3 axes = (uvec3(emitterAxes) >> uvec3(0u, 8u, 16u)) & 255u;
			uint lo = rtgiPackLightPosition(findLSB(axes)) | (emitterRange << 24u);
			uint hi = rtgiPackLightPosition(findMSB(axes));
			imageStore(rtgiEmitterCells, cell, uvec4(lo | rtgiLightRecordFlag, hi, 0u, 0u));
		}
		return;
	}

	if (gl_LocalInvocationIndex == 0u) {
		uvec4 entries;
		for (int i = 0; i < 4; ++i) entries[i] = emitterEntries[i * 2] | (emitterEntries[i * 2 + 1] << 15u);
		imageStore(rtgiEmitterCells, cell, entries);
	}
}

#else
layout(local_size_x = 1) in;
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
