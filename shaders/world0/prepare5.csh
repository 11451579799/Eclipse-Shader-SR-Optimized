#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"

#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS

layout(local_size_x = 8, local_size_y = 8, local_size_z = 4) in;
layout(rgba32ui) uniform writeonly uimage3D rtgiEmitterCells;
uniform vec3 cameraPosition;
uniform usampler1D texBlockData;

#include "/lib/blocks.glsl"
#include "/lib/voxel_common.glsl"
#include "/lib/rtgi_light_grid.glsl"

#if LPV_SIZE == 6
	const ivec3 workGroups = ivec3(9, 9, 9);
#else
	const ivec3 workGroups = ivec3(17, 17, 17);
#endif
shared uint emitterCount;
shared uint emitterEntries[8];
shared uint emitterOctants[8];
shared uint untrackedAxes;
shared uint untrackedRange;
shared uint portalIndex;

void main() {
	ivec3 cell = ivec3(gl_WorkGroupID);
	ivec3 boundsCell = cell + ivec3(0, 0, rtgiLightGridCells);
	ivec3 base = cell * rtgiLightCellSize + rtgiLightGridMin();
	vec3 camera = fract(cameraPosition) + float(VoxelSize / 2u);
	vec3 gap = rtgiCellGap(camera, vec3(base), vec3(base + rtgiLightCellSize));
	float radius = rtgiLightCoverageRadius + rtgiLightRange + rtgiLightFallbackFade;
	if (dot(gap, gap) >= radius * radius) {
		if (gl_LocalInvocationIndex == 0u) {
			imageStore(rtgiEmitterCells, cell, uvec4(0u));
			imageStore(rtgiEmitterCells, boundsCell, uvec4(0u));
		}
		return;
	}

	if (gl_LocalInvocationIndex == 0u) {
		emitterCount = 0u;
		untrackedAxes = 0u;
		untrackedRange = 0u;
		portalIndex = 0xffffffffu;
	}
	if (gl_LocalInvocationIndex < 8u) {
		emitterEntries[gl_LocalInvocationIndex] = 0u;
		emitterOctants[gl_LocalInvocationIndex] = 0xffffffffu;
	}
	barrier();

	uvec2 localEmitters = uvec2(0u);
	uint localAxes = 0u;
	uint localRange = 0u;
	for (uint layer = 0u; layer < 2u; ++layer) {
		uint index = gl_LocalInvocationIndex + 256u * layer;
		ivec3 offset = rtgiEmitterVoxelOffset(index);
		ivec3 voxel = base + offset;
		if (any(lessThan(voxel, ivec3(0))) || any(greaterThanEqual(voxel, ivec3(VoxelSize)))) continue;
		uint rawId = imageLoad(imgVoxelMask, voxel).r;
		if (rawId >= BLOCK_IRON_DOOR_TOP_N && rawId <= BLOCK_IRON_DOOR_TOP_W) atomicMin(portalIndex, index);
		if (rawId == 0u || rawId == 1u) continue;
		uint range = rawId >= 50000u ? uint(rtgiLightRange) : texelFetch(texBlockData, int(rawId % 2000u), 0).r >> 24u;
		if (range == 0u) continue;
		bool untracked = rawId >= 2000u || range > uint(rtgiLightRange);
		range = min(range, uint(rtgiLightRange));
		if (untracked) {
			localAxes |= (1u << uint(offset.x)) | (1u << uint(8 + offset.y)) | (1u << uint(16 + offset.z));
			localRange = max(localRange, range);
		} else {
			uint entry = index | (range << 9u);
			localEmitters[layer] = entry;
			uint slot = atomicAdd(emitterCount, 1u);
			if (slot < 8u) emitterEntries[slot] = entry;
		}
	}
	if (localAxes != 0u) {
		atomicOr(untrackedAxes, localAxes);
		atomicMax(untrackedRange, localRange);
	}
	barrier();

	// Keep one real emitter per octant in dense cells. Bounds alone cannot
	// distinguish an exposed emitter from one above an opaque ceiling.
	if (emitterCount > 8u) {
		for (int layer = 0; layer < 2; ++layer) {
			uint entry = localEmitters[layer];
			if (entry == 0u) continue;
			ivec3 offset = rtgiEmitterVoxelOffset(entry);
			ivec3 octant = offset / 4;
			int bin = octant.x + 2 * octant.y + 4 * octant.z;
			ivec3 centered = (offset % 4) * 2 - 3;
			uint distanceRank = uint(centered.x * centered.x + centered.y * centered.y + centered.z * centered.z);
			uint strengthRank = uint(rtgiLightRange) - (entry >> 9u);
			atomicMin(emitterOctants[bin], (strengthRank << 20u) | (distanceRank << 14u) | entry);
		}
		barrier();
	}

	if (gl_LocalInvocationIndex == 0u) {
		uvec4 entries = uvec4(0u);
		int count = 0;
		for (int i = 0; i < 8; ++i) {
			uint entry = emitterCount > 8u ? emitterOctants[i] : emitterEntries[i];
			if (entry == 0xffffffffu || entry == 0u) continue;
			entries[count / 2] |= (entry & 0x3fffu) << ((count % 2) * 15);
			++count;
		}
		uvec4 bounds = uvec4(0u);
		if (portalIndex != 0xffffffffu) bounds.z = portalIndex + 1u;
		if (untrackedRange != 0u) {
			uvec3 axes = (uvec3(untrackedAxes) >> uvec3(0u, 8u, 16u)) & 255u;
			uint lo = rtgiPackLightPosition(findLSB(axes)) | (untrackedRange << 24u);
			uint hi = rtgiPackLightPosition(findMSB(axes));
			bounds.xy = uvec2(lo, hi);
			entries.x |= rtgiLightRecordFlag;
		}
		imageStore(rtgiEmitterCells, boundsCell, bounds);
		imageStore(rtgiEmitterCells, cell, entries);
	}
}

#else
layout(local_size_x = 1) in;
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
