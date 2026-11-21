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
		samplesWorldSky = rtgiVoxelReceiver(position, surface.flatNormal);
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
	vec3 direction = rtgiDirection(tile, normalize(mix(historyNormal, surface.worldNormal, 0.45)));
	vec4 sampleLighting = vec4(0.0);
	bool needsScreen = true;
	#ifdef ECLIPSE_RTGI_WORLD
		if (samplesWorldSky) {
			// A shading normal can send a sample below the actual block face.
			// Redirect it within the geometric hemisphere for both GI and contact rays.
			if (dot(direction, surface.flatNormal) <= 0.0)
				direction = reflect(direction, surface.flatNormal);
			needsScreen = rtgiWorldBounce(position, surface.flatNormal, direction, surface.skylight, sampleLighting)
				== rtgiRayUnknown;
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

	// Store traced sky coverage in the sign of the temporal sample count.
	vec4 geometry = vec4(rtgiEncodeNormal(historyNormal), samplesWorldSky ? -sampleCount : sampleCount, -surface.viewPosition.z);
	// Keep contact occlusion responsive when nearby geometry changes.
	vec2 sampleWeight = 1.0 / vec2(sampleCount, min(sampleCount, 10.0));
	vec4 lighting = mix(previousLighting, sampleLighting, sampleWeight.xxxy);
	rtgiStoreTile(tile, evenFrame, geometry, lighting);
}

#else

const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}

#endif
