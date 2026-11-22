#include "/lib/settings.glsl"
#include "/lib/res_params.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

uniform float viewWidth;
uniform float viewHeight;
uniform int frameCounter;
uniform mat4 gbufferProjectionInverse;

#define ECLIPSE_RTGI_TRACE
#include "/lib/rtgi_buffers.glsl"

#ifdef ECLIPSE_RTGI_ACTIVE

const vec2 workGroupsRender = vec2(0.33333334, 0.33333334);

uniform sampler2D depthtex1;
uniform sampler2D colortex1;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform mat4 gbufferProjection;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform float frameTimeCounter;
uniform float sunElevation;
uniform float rainStrength;
uniform int isEyeInWater;

#include "/lib/opaque_gbuffer.glsl"
#include "/lib/rtgi_world.glsl"
#ifdef ECLIPSE_RTGI_WORLD
	uniform sampler2D colortex8;
#endif

struct RtgiSurface {
	vec3 viewPosition;
	vec3 worldNormal;
	#ifdef ECLIPSE_RTGI_WORLD
		vec3 flatNormal;
		float skylight;
	#endif
};

bool rtgiReadSurface(ivec2 pixel, float depth, vec2 inverseViewport, vec2 jitter, out RtgiSurface surface) {
	if (depth <= 0.0 || depth >= 1.0) return false;

	vec4 data = texelFetch(colortex1, pixel, 0);
	if (!rtgiStaticSurface(decodeVec2(data.w).y) || texelFetch(colortex7, pixel, 0).a > 0.99) return false;

	vec2 uv = (vec2(pixel) + 0.5 - jitter) * inverseViewport;
	vec4 view = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	surface.viewPosition = view.xyz / view.w;
	surface.worldNormal = decode(vec2(decodeVec2(data.x).y, decodeVec2(data.y).y));
	#ifdef ECLIPSE_RTGI_WORLD
		vec3 packedNormal = texelFetch(colortex8, pixel, 0).xyz;
		surface.flatNormal = normalize(vec3(decodeVec2(packedNormal.x).y, decodeVec2(packedNormal.y).y,
			decodeVec2(packedNormal.z).y) * 2.0 - 1.0);
		surface.skylight = decodeVec2(data.w).x;
	#endif
	return surface.viewPosition.z < 0.0 && dot(surface.viewPosition, surface.viewPosition) <= rtgiViewRange * rtgiViewRange;
}

bool rtgiHistoryAvailable(ivec2 renderSize) {
	return rtgiPreviousFrame + 1 == frameCounter
		&& all(equal(rtgiPreviousRenderSize, renderSize))
		&& abs(frameTimeCounter - rtgiPreviousTime) < 0.5
		&& (sunElevation > 1e-5) == (rtgiPreviousSun > 1e-5)
		&& abs(sunElevation - rtgiPreviousSun) < 0.04
		&& abs(rainStrength - rtgiPreviousRain) < 0.12
		&& distance(cameraPosition, previousCameraPosition) < 8.0;
}

struct RtgiHistoryFootprint {
	vec2 pixel;
	vec2 slope;
	float depth;
};

float rtgiHistorySurface(ivec2 tile, bool evenFrame, vec3 normal, RtgiHistoryFootprint footprint, out vec4 geometry) {
	geometry = evenFrame ? imageLoad(rtgiSurface1, tile) : imageLoad(rtgiSurface0, tile);
	if (geometry.w <= 0.0 || abs(geometry.w - footprint.depth) > 0.10 + footprint.depth * 0.16) return 0.0;
	vec2 offset = vec2(rtgiTilePixel(tile, rtgiPreviousRenderSize)) + 0.5 - footprint.pixel;
	float plane = 1.0 - rtgiDepthError(footprint.depth, geometry.w, footprint.slope, offset)
		/ rtgiDepthTolerance(footprint.depth);
	float alignment = dot(rtgiDecodeNormal(geometry.xy), normal);
	if (plane <= 0.0 || alignment < 0.85) return 0.0;
	vec2 tent = max(1.0 - abs(offset) / float(rtgiSampleStride()), 0.0);
	return plane * plane * alignment * tent.x * tent.y;
}

bool rtgiReproject(
	RtgiSurface surface, vec2 viewport, out RtgiHistoryFootprint footprint
) {
	vec3 world = (gbufferModelViewInverse * vec4(surface.viewPosition, 1.0)).xyz;
	world += cameraPosition - previousCameraPosition;
	vec4 view = gbufferPreviousModelView * vec4(world, 1.0);
	vec4 clip = gbufferPreviousProjection * view;
	if (clip.w <= 0.0) return false;

	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	vec2 pixel = uv * viewport + rtgiPreviousJitter;
	if (any(lessThan(pixel, vec2(0.0))) || any(greaterThanEqual(pixel, vec2(rtgiPreviousRenderSize)))) return false;

	#ifdef ECLIPSE_RTGI_WORLD
		vec3 normal = surface.flatNormal;
	#else
		vec3 normal = surface.worldNormal;
	#endif
	footprint = RtgiHistoryFootprint(pixel,
		rtgiDepthSlope(view.xyz, mat3(gbufferPreviousModelView) * normal, viewport, gbufferPreviousProjection), -view.z);
	return true;
}

vec4 rtgiGatherHistory(RtgiHistoryFootprint footprint, ivec2 tileSize, bool evenFrame, vec3 normal, bool samplesWorldSky,
	bool sourceLighting, out ivec2 nearestTile, out float nearestWeight, out float count) {
	int stride = rtgiSampleStride();
	ivec2 base = ivec2(floor((footprint.pixel - (float(stride / 2) + 0.5)) / float(stride)));
	vec4 lighting = vec4(0.0);
	float weightSum = 0.0;
	nearestTile = ivec2(0);
	count = 0.0;
	nearestWeight = 0.0;
	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			ivec2 tile = base + ivec2(x, y);
			if (!rtgiContains(tile, tileSize)) continue;
			vec4 geometry;
			float weight = rtgiHistorySurface(tile, evenFrame, normal, footprint, geometry);
			if (weight <= 0.0) continue;
			if (weight > nearestWeight) {
				nearestTile = tile;
				nearestWeight = weight;
			}
			if (!sourceLighting && (geometry.z < 0.0) != samplesWorldSky) continue;
			vec4 value = sourceLighting ? imageLoad(rtgiLight, tile)
				: imageLoad(rtgiHistory, rtgiHistoryPixel(tile, !evenFrame, imageSize(rtgiHistory)));
			if (sourceLighting && value.a <= 0.0) continue;
			lighting += value * weight;
			count += abs(geometry.z) * weight;
			weightSum += weight;
		}
	}
	count = count / max(1e-5, weightSum) * smoothstep(0.01, 0.30, weightSum);
	return lighting / max(1e-5, weightSum);
}

#ifdef ECLIPSE_RTGI_WORLD
// Screen radiance replaces only the analytic direct term at the same full-block face.
// Each tile is validated in the current frame and against its previous-frame geometry.
vec4 rtgiVoxelScreenDirect(RtgiVoxelHit voxelHit, vec3 hitPosition, ivec2 renderSize,
	ivec2 tileSize, vec2 viewport, vec2 jitter, bool evenFrame) {
	if (!rtgiFullVoxel(voxelHit.blockId) || rtgiSolidEmitter(voxelHit.blockId)) return vec4(0.0);
	vec3 playerHit = hitPosition - rtgiVoxelOffset();
	vec4 clip = gbufferProjection * gbufferModelView * vec4(playerHit, 1.0);
	if (clip.w <= 0.0) return vec4(0.0);
	vec2 raster = (clip.xy / clip.w * 0.5 + 0.5) * viewport + jitter;
	float stride = float(rtgiSampleStride());
	if (any(lessThan(raster, vec2(stride))) || any(greaterThanEqual(raster, vec2(renderSize) - stride))) return vec4(0.0);
	// Choose the closest tile once; smoothly reduce trust toward tile boundaries.
	ivec2 tile = ivec2(floor(raster / stride));
	if (!rtgiContains(tile, tileSize)) return vec4(0.0);
	ivec2 pixel = rtgiTilePixel(tile, renderSize);
	vec2 tileOffset = abs(raster - (vec2(pixel) + 0.5)) / stride;
	float tileWeight = 1.0 - smoothstep(0.32, 0.71, length(tileOffset));
	if (tileWeight <= 0.0) return vec4(0.0);
	RtgiSurface candidate;
	if (!rtgiReadSurface(pixel, texelFetch(depthtex1, pixel, 0).r, 1.0 / viewport, jitter, candidate)) return vec4(0.0);
	if (dot(candidate.flatNormal, voxelHit.normal) < 0.98) return vec4(0.0);
	vec3 point = (gbufferModelViewInverse * vec4(candidate.viewPosition, 1.0)).xyz + rtgiVoxelOffset();
	ivec3 receiverVoxel; uint receiverId;
	if (!rtgiVoxelReceiver(point, candidate.flatNormal, receiverVoxel, receiverId)
		|| any(notEqual(receiverVoxel, voxelHit.voxel)) || receiverId != voxelHit.blockId) return vec4(0.0);
	vec3 separation = point - hitPosition;
	if (abs(dot(separation, voxelHit.normal)) > 0.06 || length(separation) > 0.35) return vec4(0.0);
	// colortex8 stores (F0, flat-normal Y) in y and (emission, AO) in w.
	vec4 materialData = texelFetch(colortex8, pixel, 0);
	float f0 = decodeVec2(materialData.y).x;
	float emission = decodeVec2(materialData.w).x;
	if (f0 > 229.5 / 255.0 || (emission > 0.5 / 255.0 && emission < 254.5 / 255.0)) return vec4(0.0);
	RtgiHistoryFootprint previous;
	if (!rtgiReproject(candidate, viewport, previous)) return vec4(0.0);
	ivec2 oldTile = ivec2(floor(previous.pixel / stride));
	if (!rtgiContains(oldTile, tileSize)) return vec4(0.0);
	vec4 oldGeometry;
	float valid = rtgiHistorySurface(oldTile, evenFrame, candidate.flatNormal, previous, oldGeometry);
	if (valid <= 0.0 || dot(rtgiDecodeNormal(oldGeometry.xy), voxelHit.normal) < 0.98) return vec4(0.0);
	vec2 oldOffset = vec2(rtgiTilePixel(oldTile, rtgiPreviousRenderSize)) + 0.5 - previous.pixel;
	float error = rtgiDepthError(previous.depth, oldGeometry.w, previous.slope, oldOffset);
	if (error > 0.06 || length(oldOffset) > stride * 0.6) return vec4(0.0);
	vec4 direct = imageLoad(rtgiLight, oldTile);
	if (direct.a <= 0.0) return vec4(0.0);
	float motion = length(vec2(pixel) + 0.5 - jitter - previous.pixel + rtgiPreviousJitter);
	float weight = valid * tileWeight * (1.0 - smoothstep(0.10, 0.35, length(separation)))
		* (1.0 - smoothstep(1.0, 6.0, motion));
	// Source light is linear scene radiance, not the exposure-adjusted display color.
	// Reduce trust when the sun or weather changes within the accepted history window.
	weight *= (1.0 - smoothstep(0.005, 0.04, abs(sunElevation - rtgiPreviousSun)))
		* (1.0 - smoothstep(0.02, 0.12, abs(rainStrength - rtgiPreviousRain)));
	return vec4(max(direct.rgb, vec3(0.0)), 0.65 * weight);
}
#endif

vec2 rtgiSamplePhase(ivec2 tile) {
	// Composite colortex6 exposes the pack's two-channel blue-noise texture.
	ivec2 noisePixel = tile % textureSize(colortex6, 0);
	return texelFetch(colortex6, noisePixel, 0).rg;
}

vec2 rtgiSamplePair(ivec2 tile) {
	return fract(rtgiSamplePhase(tile) + vec2(0.75487767, 0.56984029) * float(frameCounter % 4096));
}

vec3 rtgiDirection(ivec2 tile, vec3 normal) {
	vec2 samplePoint = rtgiSamplePair(tile);
	float radius = sqrt(samplePoint.x);
	float phi = 6.283185307 * samplePoint.y;
	vec3 axis = abs(normal.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
	vec3 tangent = normalize(cross(axis, normal));
	vec3 bitangent = cross(normal, tangent);
	return tangent * (radius * cos(phi)) + bitangent * (radius * sin(phi))
		+ normal * sqrt(1.0 - samplePoint.x);
}

#ifdef ECLIPSE_RTGI_WORLD
bool rtgiPrimaryGuide(ivec3 voxel, uint blockId, vec3 flatNormal, float skylight, out vec3 guide) {
	if (skylight >= 0.75 || !rtgiFullVoxel(blockId) || rtgiSolidEmitter(blockId)) return false;
	uint material = rtgiVoxelMaterialAt(voxel, flatNormal);
	if (material == 0u) return false;
	ivec4 key = rtgiFaceKey(voxel, flatNormal, blockId);
	uint slot = rtgiFaceHash(key) & (rtgiFaceCacheSize - 1u);
	RtgiFaceEntry entry = rtgiFaces[slot];
	uint age = uint(frameCounter) + 1u - entry.data.x;
	if (entry.data.x == 0u || age > 16u || entry.data.w != material || any(notEqual(entry.key, key))) return false;
	uint encodedGuide = rtgiFaceGuides[slot];
	if (unpackHalf2x16(encodedGuide).y <= 0.0001) return false;
	guide = rtgiUnpackGuide(encodedGuide);
	return dot(guide, flatNormal) > 0.0;
}

uint rtgiPrimaryRandom(uint v) {
	v ^= v >> 16u; v *= 0x7feb352du;
	v ^= v >> 15u; v *= 0x846ca68bu;
	return v ^ (v >> 16u);
}
#endif

#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
	void rtgiStoreDirect(ivec2 tile, bool evenFrame, uvec4 direct) {
		imageStore(rtgiDirect, rtgiHistoryPixel(tile, evenFrame, imageSize(rtgiDirect)), direct);
	}

	void rtgiSampleDirect(ivec2 tile, bool evenFrame, vec3 position, RtgiSurface surface,
		bool useHistory, ivec2 historyTile, float screenMotion, bool reuse) {
		uvec4 previous = uvec4(0u);
		if (useHistory) {
			previous = imageLoad(rtgiDirect, rtgiHistoryPixel(historyTile, !evenFrame, imageSize(rtgiDirect)));
			if (reuse && previous.w >= 1u) {
				rtgiStoreDirect(tile, evenFrame, previous);
				return;
			}
		}

		vec2 samplePoint = rtgiSamplePair(tile + ivec2(103, 233));
		float phi = 6.283185307 * samplePoint.y;
		vec2 disk = sqrt(samplePoint.x) * vec2(cos(phi), sin(phi));
		uint lightKey;
		// Sample both sides of an equally weighted boundary every two frames.
		float cellPhase = rtgiSamplePhase(tile + ivec2(311, 79)).x;
		float cellSample = fract(cellPhase + 0.61803399 * float((frameCounter / 2) % 2048)
			+ 0.5 * float(frameCounter & 1));
		vec4 direct = rtgiLocalLighting(position, surface.flatNormal, surface.worldNormal, disk, cellSample, true, lightKey);
		direct.rgb *= direct.a;

		uint count = 1u;
		if (useHistory && direct.a > 0.0) {
			vec4 history = rtgiUnpackDirect(previous);
			if (previous.z == lightKey && abs(history.a - direct.a) < 0.10) {
				count += min(previous.w, uint(mix(23.0, 6.0, smoothstep(0.75, 10.0, screenMotion))));
				direct = mix(history, direct, 1.0 / float(count));
			}
		}
		rtgiStoreDirect(tile, evenFrame, uvec4(packHalf2x16(direct.xy), packHalf2x16(direct.zw), lightKey, count));
	}
#endif

bool rtgiRayDepth(
	vec4 clip, float viewDepth, vec2 halfViewport, vec2 rasterOffset, ivec2 renderSize,
	out ivec2 pixel, out float depth, out float gap
) {
	if (clip.w <= 0.0 || abs(clip.z) > clip.w) return false;
	vec2 raster = clip.xy / clip.w * halfViewport + rasterOffset;
	if (any(lessThan(raster, vec2(0.0))) || any(greaterThanEqual(raster, vec2(renderSize)))) return false;
	pixel = ivec2(raster);
	depth = texelFetch(depthtex1, pixel, 0).r;
	gap = depth <= 0.0 || depth >= 1.0 ? -1.0 : viewDepth - rtgiLinearDepth(depth);
	return true;
}

bool rtgiTrace(
	RtgiSurface surface, vec3 direction, ivec2 originPixel, ivec2 renderSize, vec2 viewport, vec2 jitter,
	out RtgiSurface hit, out float hitDistance
) {
	const float maxDistance = 12.0;
	vec3 viewNormal = normalize(mat3(gbufferModelView) * surface.worldNormal);
	vec3 viewDirection = mat3(gbufferModelView) * direction;
	vec3 origin = surface.viewPosition + viewNormal * 0.08;
	vec4 clipOrigin = gbufferProjection * vec4(origin, 1.0);
	vec4 clipDirection = gbufferProjection * vec4(viewDirection, 0.0);
	vec2 halfViewport = viewport * 0.5;
	vec2 rasterOffset = halfViewport + jitter;
	float previousDistance = 0.0;

	for (int stepIndex = 0; stepIndex < RTGI_STEPS; ++stepIndex) {
		float progress = float(stepIndex + 1) / float(RTGI_STEPS);
		float travel = mix(0.18, maxDistance, progress * progress);
		float viewDepth = -origin.z - viewDirection.z * travel;
		ivec2 pixel;
		float depth;
		float gap;
		if (!rtgiRayDepth(clipOrigin + clipDirection * travel, viewDepth, halfViewport, rasterOffset, renderSize, pixel, depth, gap)) return false;
		if (gap < 0.0 || all(equal(pixel, originPixel))) {
			previousDistance = travel;
			continue;
		}

		float thickness = clamp(viewDepth * 0.014, 0.10, 0.35);
		if (gap > thickness) {
			// A coarse crossing can pass a thin surface in one step.
			float front = previousDistance;
			float back = travel;
			for (int refine = 0; refine < 2; ++refine) {
				float middle = (front + back) * 0.5;
				ivec2 candidate;
				float candidateDepth;
				float candidateGap;
				float middleDepth = -origin.z - viewDirection.z * middle;
				if (!rtgiRayDepth(clipOrigin + clipDirection * middle, middleDepth, halfViewport, rasterOffset, renderSize, candidate, candidateDepth, candidateGap)) return false;
				if (candidateGap < 0.0 || all(equal(candidate, originPixel))) {
					front = middle;
				} else {
					back = middle;
					pixel = candidate;
					depth = candidateDepth;
					gap = candidateGap;
				}
			}
		}

		if (gap > thickness || !rtgiReadSurface(pixel, depth, 1.0 / viewport, jitter, hit)) return false;
		hitDistance = distance(hit.viewPosition, surface.viewPosition);
		return hitDistance >= 0.16 && dot(hit.worldNormal, -direction) > 0.05;
	}
	return false;
}

void rtgiStoreTile(ivec2 tile, bool evenFrame, vec4 surface, vec4 lighting) {
	if (evenFrame) imageStore(rtgiSurface0, tile, surface);
	else imageStore(rtgiSurface1, tile, surface);
	imageStore(rtgiHistory, rtgiHistoryPixel(tile, evenFrame, imageSize(rtgiHistory)), lighting);
}

void main() {
	ivec2 renderSize = rtgiRenderSize();
	ivec2 tileSize = rtgiTileSize(renderSize);
	ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
	if (!rtgiContains(tile, tileSize)) return;

	bool evenFrame = rtgiEvenFrame();
	ivec2 pixel = rtgiTilePixel(tile, renderSize);
	vec2 viewport = rtgiViewportSize();
	vec2 jitter = rtgiJitterPixels();
	RtgiSurface surface;
	if (isEyeInWater != 0 || !rtgiReadSurface(pixel, texelFetch(depthtex1, pixel, 0).r, 1.0 / viewport, jitter, surface)) {
		rtgiStoreTile(tile, evenFrame, vec4(0.0), vec4(0.0));
		#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
			rtgiStoreDirect(tile, evenFrame, uvec4(0u));
		#endif
		return;
	}

	bool historyAvailable = rtgiHistoryAvailable(renderSize);

	ivec2 historyTile = ivec2(0);
	vec3 historyNormal = surface.worldNormal;
	bool samplesWorldSky = false;
	#ifdef ECLIPSE_RTGI_WORLD
		vec3 position = (gbufferModelViewInverse * vec4(surface.viewPosition, 1.0)).xyz + rtgiVoxelOffset();
		ivec3 receiverVoxel;
		uint receiverId;
		samplesWorldSky = rtgiVoxelReceiver(position, surface.flatNormal, receiverVoxel, receiverId);
		historyNormal = surface.flatNormal;
	#endif

	vec4 previousLighting = vec4(0.0);
	float sampleCount = 1.0;
	RtgiHistoryFootprint footprint;
	bool useHistory = historyAvailable && rtgiReproject(surface, viewport, footprint);
	float screenMotion = 0.0;
	float historyWeight = 0.0;
	if (useHistory) {
		screenMotion = length(vec2(pixel) + 0.5 - jitter - footprint.pixel + rtgiPreviousJitter);
		float historyCount;
		previousLighting = rtgiGatherHistory(footprint, tileSize, evenFrame, historyNormal, samplesWorldSky,
			false, historyTile, historyWeight, historyCount);
		sampleCount += min(historyCount, mix(31.0, 8.0, smoothstep(1.0, 12.0, screenMotion)));
	}
	bool reuse = rtgiSampleStride() >= 4 && samplesWorldSky && sampleCount > 10.0 && historyWeight > 0.46 && screenMotion < 1.25
		&& (((tile.x >> 2) ^ (tile.y >> 2) ^ frameCounter) & 1) == 0;
	#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
		rtgiSampleDirect(tile, evenFrame, position, surface, historyWeight > 0.06, historyTile, screenMotion, reuse);
	#endif

	if (reuse) {
		// Converged neighboring tiles take turns refreshing. Disocclusions
		// and fast motion still get a fresh ray every frame.
		vec4 geometry = vec4(rtgiEncodeNormal(historyNormal), -(sampleCount - 1.0), -surface.viewPosition.z);
		rtgiStoreTile(tile, evenFrame, geometry, previousLighting);
		return;
	}

	RtgiSurface hit;
	float hitDistance;
	vec3 sampleNormal = normalize(mix(historyNormal, surface.worldNormal, 0.45));
	vec3 direction = rtgiDirection(tile, sampleNormal);
	float proposalWeight = 1.0;
	bool guidedProposal = false;
	#ifdef ECLIPSE_RTGI_WORLD
		vec3 guide;
		// Restrict to near-flat shading normals so the geometric hemisphere remains reliable.
		if (samplesWorldSky && dot(sampleNormal, surface.flatNormal) > 0.995
			&& rtgiPrimaryGuide(receiverVoxel, receiverId, surface.flatNormal, surface.skylight, guide)) {
			guidedProposal = true;
			uint seed = uint(tile.x) * 0x8da6b343u ^ uint(tile.y) * 0xd8163841u ^ uint(frameCounter) * 0xcb1ab31fu;
			float selectGuide = float(rtgiPrimaryRandom(seed) & 0x00ffffffu) * (1.0 / 16777216.0);
			if (selectGuide < 0.25) direction = rtgiDirection(tile, guide);
			float cosine = max(dot(sampleNormal, direction), 0.0);
			float mixture = 0.75 * cosine + 0.25 * max(dot(guide, direction), 0.0);
			proposalWeight = mixture > 0.0 ? cosine / mixture : 0.0;
			if (dot(direction, surface.flatNormal) <= 0.0) proposalWeight = 0.0;
		}
	#endif
	vec4 sampleLighting = vec4(0.0);
	bool needsScreen = true;
	#ifdef ECLIPSE_RTGI_WORLD
		if (samplesWorldSky) {
			// A shading normal can send a sample below the actual block face.
			// Redirect it within the geometric hemisphere for both GI and contact rays.
			if (!guidedProposal && dot(direction, surface.flatNormal) <= 0.0)
				direction = reflect(direction, surface.flatNormal);
			RtgiVoxelHit voxelHit;
			vec3 transmission, voxelDirect;
			float rangeWeight;
			int worldResult = rtgiWorldBounce(position, surface.flatNormal, direction, surface.skylight,
				sampleLighting, voxelHit, transmission, voxelDirect, rangeWeight);
			needsScreen = worldResult == rtgiRayUnknown;
			if (worldResult == rtgiRayHit && historyAvailable
				&& max(voxelDirect.r, max(voxelDirect.g, voxelDirect.b)) >= 0.7) {
				vec3 hitPosition = position + surface.flatNormal * rtgiRayBias + direction * voxelHit.distance;
				vec4 screenDirect = rtgiVoxelScreenDirect(voxelHit, hitPosition, renderSize, tileSize, viewport, jitter, evenFrame);
				sampleLighting.rgb += transmission * rangeWeight * (screenDirect.rgb - voxelDirect) * screenDirect.a;
			}
			if (needsScreen) sampleLighting.rgb = rtgiEscapedSkylight(direction, surface.skylight);
		}
	#endif
	if (needsScreen) {
		bool hasScreenLight = false;
		if (rtgiTrace(surface, direction, pixel, renderSize, viewport, jitter, hit, hitDistance)) {
			sampleLighting.a = 1.0 - smoothstep(0.16, 2.0, hitDistance);
			RtgiHistoryFootprint hitHistory;
			if (historyAvailable && rtgiReproject(hit, viewport, hitHistory)) {
				float unusedWeight, unusedCount;
				#ifdef ECLIPSE_RTGI_WORLD
					vec3 hitNormal = hit.flatNormal;
				#else
					vec3 hitNormal = hit.worldNormal;
				#endif
				vec4 direct = rtgiGatherHistory(hitHistory, tileSize, evenFrame, hitNormal, false,
					true, historyTile, unusedWeight, unusedCount);
				hasScreenLight = direct.a > 0.0;
				if (hasScreenLight) sampleLighting.rgb = max(direct.rgb, vec3(0.0));
			}
		}
		#ifdef ECLIPSE_RTGI_WORLD
			if (!hasScreenLight && !samplesWorldSky) {
				vec4 fallback;
				rtgiWorldBounce(position, surface.flatNormal, direction, 0.0, fallback);
				sampleLighting.rgb = fallback.rgb;
				sampleLighting.a = max(sampleLighting.a, fallback.a);
			}
		#endif
	}

	// Reweight both light and contact coverage for the mixture, bounding the latter.
	if (guidedProposal) {
		sampleLighting.rgb *= proposalWeight;
		sampleLighting.a = clamp(sampleLighting.a * proposalWeight, 0.0, 1.0);
	}

	#ifdef ECLIPSE_RTGI_WORLD
		if (historyAvailable && samplesWorldSky && sampleCount < 5.0 && surface.skylight < 0.75) {
			uint material = rtgiVoxelMaterialAt(receiverVoxel, surface.flatNormal);
			if (material != 0u) {
				vec3 unusedDirect, cachedBounce;
				float freshness;
				rtgiLoadFace(rtgiFaceKey(receiverVoxel, surface.flatNormal, receiverId),
					material, unusedDirect, cachedBounce, freshness);
				// Start newly exposed surfaces with some world-space irradiance.
				// Both terms estimate the same incoming light.
				float cacheWeight = 0.5 * freshness * (1.0 - smoothstep(1.0, 5.0, sampleCount))
					* (1.0 - smoothstep(0.25, 0.75, surface.skylight));
				sampleLighting.rgb = mix(sampleLighting.rgb, cachedBounce, cacheWeight);
			}
		}
	#endif

	// Store traced sky coverage in the sign of the temporal sample count.
	vec4 geometry = vec4(rtgiEncodeNormal(historyNormal), samplesWorldSky ? -sampleCount : sampleCount, -surface.viewPosition.z);
	// Keep contact occlusion responsive when nearby geometry changes.
	vec2 sampleWeight = 1.0 / vec2(sampleCount, min(sampleCount, 10.0));
	// A proposal below the geometric face carries no contact observation.
	if (guidedProposal && proposalWeight <= 0.0) sampleWeight.y = 0.0;
	vec4 lighting = mix(previousLighting, sampleLighting, sampleWeight.xxxy);
	rtgiStoreTile(tile, evenFrame, geometry, lighting);
}

#else

const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}

#endif
