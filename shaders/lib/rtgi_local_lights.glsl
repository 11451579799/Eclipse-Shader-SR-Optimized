#ifndef ECLIPSE_RTGI_LOCAL_LIGHTS_INCLUDED
#define ECLIPSE_RTGI_LOCAL_LIGHTS_INCLUDED

#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
    #define ECLIPSE_RTGI_LOCAL_LIGHTS

    // Eclipse LPV injects levels 1 through 16 and uses one 8^3 workgroup per tile.
    const int rtgiLightTileSize = 8;
    const float rtgiLightSearchRange = 16.0;
    const uint rtgiLightEntryMask = 0x3fffu;
    const uint rtgiLightOverflow = 1u << 28;
    const uint rtgiLightUntracked = 31u;

    #ifdef RENDER_SHADOWCOMP
        layout(r32ui) uniform writeonly uimage3D imgRtgiLightTiles;
        shared uint rtgiTileEmitterCount;
        shared uint rtgiTileEmitters[2];

        void rtgiBeginLightTile() {
            if (gl_LocalInvocationIndex == 0u) {
                rtgiTileEmitterCount = 0u;
                rtgiTileEmitters[0] = 0u;
                rtgiTileEmitters[1] = 0u;
            }
            // The LPV workgroup barrier makes the initialization visible.
        }

        void rtgiRegisterLight(ivec3 voxel, float lightRange) {
            if (lightRange <= 0.0) return;
            uint slot = atomicAdd(rtgiTileEmitterCount, 1u);
            if (slot >= 2u) return;

            uint rawBlockId = imageLoad(imgVoxelMask, voxel).r;
            uint range = uint(round(lightRange));
            if (rawBlockId >= 2000u || range > uint(rtgiLightSearchRange)) {
                // Entity and beacon light keep their native LPV contribution.
                range = rtgiLightUntracked;
            }
            rtgiTileEmitters[slot] = gl_LocalInvocationIndex | (range << 9u);
        }

        void rtgiEndLightTile() {
            barrier();
            if (gl_LocalInvocationIndex != 0u) return;

            uint tileData = rtgiTileEmitters[0] | (rtgiTileEmitters[1] << 14u);
            if (rtgiTileEmitterCount > 2u) tileData |= rtgiLightOverflow;
            tileData |= (uint(frameCounter) & 7u) << 29u;
            imageStore(imgRtgiLightTiles, ivec3(gl_WorkGroupID), uvec4(tileData));
        }
    #else
        layout(r32ui) uniform readonly uimage3D imgRtgiLightTiles;

        bool rtgiLocalLightContains(ivec3 voxel) {
            return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, ivec3(VoxelSize)));
        }

        bool rtgiLocalLightUnoccluded(vec3 origin, ivec3 source) {
            ivec3 voxel = ivec3(floor(origin));
            if (voxel == source) return true;

            vec3 direction = vec3(source) + 0.5 - origin;
            ivec3 increment = ivec3(sign(direction));
            vec3 stride = 1.0 / max(abs(direction), vec3(1e-6));
            vec3 localOrigin = fract(origin);
            vec3 crossing = mix(localOrigin, 1.0 - localOrigin, greaterThan(direction, vec3(0.0))) * stride;
            crossing = mix(crossing, vec3(1e6), equal(increment, ivec3(0)));

            // A 16-block segment can cross at most 30 cells across its three axes.
            for (int iteration = 0; iteration < 30; ++iteration) {
                float travel = min(crossing.x, min(crossing.y, crossing.z));
                if (travel >= 1.0) return true;
                // Advance together at edges and corners so mere contact never occludes.
                vec3 crossed = step(crossing, vec3(travel + 1e-6));
                voxel += ivec3(crossed) * increment;
                crossing += crossed * stride;
                if (voxel == source || !rtgiLocalLightContains(voxel)) return true;

                uint blockId = imageLoad(imgVoxelMask, voxel).r;
                if (blockId == 0u || blockId >= 2000u) continue;
                uint tint = texelFetch(texBlockData, int(blockId), 0).g & 0x00ffffffu;
                if (tint == 0u) return false;
            }
            return true;
        }

        bool rtgiLightTilePreservesLpv(ivec3 tile, vec3 origin, vec3 tileOrigin, ivec3 cameraShift,
            uint frameStamp, inout int rays, inout float covered) {
            ivec3 tileBase = tile * rtgiLightTileSize;
            vec3 fromVoxelCenter = max(abs(tileOrigin - vec3(tileBase) - 4.0) - 3.5, 0.0);
            if (dot(fromVoxelCenter, fromVoxelCenter) >= rtgiLightSearchRange * rtgiLightSearchRange) return false;

            uint tileData = imageLoad(imgRtgiLightTiles, tile).r;
            if ((tileData >> 29u) != frameStamp || (tileData & rtgiLightOverflow) != 0u) return true;

            for (int slot = 0; slot < 2; ++slot, tileData >>= 14u) {
                uint entry = tileData & rtgiLightEntryMask;
                if (entry == 0u) break;
                uint range = entry >> 9u;
                ivec3 local = ivec3(entry & 7u, (entry >> 3u) & 7u, (entry >> 6u) & 7u);
                ivec3 source = tileBase + local - cameraShift;
                vec3 direction = vec3(source) + 0.5 - origin;
                float rangeLimit = min(float(range), rtgiLightSearchRange);
                float distanceSquared = dot(direction, direction);
                if (distanceSquared >= rangeLimit * rangeLimit) continue;

                if (range == rtgiLightUntracked || rays == 4 || !rtgiLocalLightContains(source)) return true;
                uint blockId = imageLoad(imgVoxelMask, source).r;
                if (blockId == 0u || blockId >= 2000u || (texelFetch(texBlockData, int(blockId), 0).r >> 24u) != range) return true;

                ++rays;
                if (rtgiLocalLightUnoccluded(origin, source)) return true;
                covered = max(covered, smoothstep(0.0, 1.5, rangeLimit - sqrt(distanceSquared)));
            }
            return false;
        }

        float rtgiLocalLightVisibility(vec3 playerPosition, vec3 worldNormal) {
            if (frameCounter <= 0 || distance(cameraPosition, previousCameraPosition) >= 8.0) return 1.0;

            // composite20 runs after opaque lighting. Its tile coordinates match the LPV
            // sampled here, while the shadow rasterization already uses the current camera.
            ivec3 cameraShift = ivec3(floor(cameraPosition) - floor(previousCameraPosition));
            vec3 origin = playerPosition + fract(cameraPosition) + float(VoxelSize / 2u) + worldNormal * 0.045;
            vec3 tileOrigin = origin + vec3(cameraShift);
            const vec3 border = vec3(rtgiLightSearchRange);
            if (any(lessThan(origin, border)) || any(greaterThan(origin, vec3(VoxelSize) - border))
                || any(lessThan(tileOrigin, border)) || any(greaterThan(tileOrigin, vec3(VoxelSize) - border))) return 1.0;

            uint frameStamp = uint(frameCounter - 1) & 7u;
            ivec3 firstTile = ivec3(floor((tileOrigin - border) / float(rtgiLightTileSize)));
            ivec3 lastTile = min(ivec3(floor((tileOrigin + border) / float(rtgiLightTileSize))), ivec3(int(VoxelSize) / rtgiLightTileSize - 1));
            ivec3 centerTile = ivec3(tileOrigin) / rtgiLightTileSize;
            float covered = 0.0;
            int rays = 0;

            // A nearby visible light can terminate the search before scanning the other tiles.
            if (rtgiLightTilePreservesLpv(centerTile, origin, tileOrigin, cameraShift, frameStamp, rays, covered)) return 1.0;
            for (int z = firstTile.z; z <= lastTile.z; ++z) {
                for (int y = firstTile.y; y <= lastTile.y; ++y) {
                    for (int x = firstTile.x; x <= lastTile.x; ++x) {
                        ivec3 tile = ivec3(x, y, z);
                        if (tile != centerTile && rtgiLightTilePreservesLpv(tile, origin, tileOrigin, cameraShift, frameStamp, rays, covered)) return 1.0;
                    }
                }
            }
            return 1.0 - 0.98 * covered;
        }
    #endif
#endif

#endif
