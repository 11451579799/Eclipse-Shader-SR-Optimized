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
#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
	uniform sampler2D colortex8;
	#include "/lib/rtgi_local_lights.glsl"
#endif

struct RtgiSurface {
	vec3 viewPosition;
	vec3 worldNormal;
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		float blockLightmap;
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
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		surface.blockLightmap = decodeVec2(data.z).y;
	#endif
	return surface.viewPosition.z < 0.0 && surface.viewPosition.z >= -rtgiViewRange;
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

bool rtgiHistorySurface(ivec2 tile, bool evenFrame, vec3 normal, float depth, vec2 slope, vec2 pixel, out vec4 geometry) {
	geometry = evenFrame ? imageLoad(rtgiSurface1, tile) : imageLoad(rtgiSurface0, tile);
	vec2 offset = vec2(rtgiTilePixel(tile, rtgiPreviousRenderSize)) + 0.5 - pixel;
	return geometry.w > 0.0 && abs(geometry.w - depth) <= 0.10 + depth * 0.16
		&& rtgiDepthError(depth, geometry.w, slope, offset) <= rtgiDepthTolerance(depth)
		&& dot(rtgiDecodeNormal(geometry.xy), normal) >= 0.85;
}

bool rtgiReproject(
	RtgiSurface surface, vec2 viewport, ivec2 tileSize, bool evenFrame,
	out ivec2 historyTile, out float historyCount, out vec2 previousPixel
) {
	vec3 world = (gbufferModelViewInverse * vec4(surface.viewPosition, 1.0)).xyz;
	world += cameraPosition - previousCameraPosition;
	vec4 view = gbufferPreviousModelView * vec4(world, 1.0);
	vec4 clip = gbufferPreviousProjection * view;
	if (clip.w <= 0.0) return false;

	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	vec2 pixel = uv * viewport + rtgiPreviousJitter;
	if (any(lessThan(pixel, vec2(0.0))) || any(greaterThanEqual(pixel, vec2(rtgiPreviousRenderSize)))) return false;

	ivec2 center = min(ivec2(pixel) / rtgiStride, tileSize - 1);
	ivec2 direction = ivec2(rtgiOctSign(pixel - vec2(rtgiTilePixel(center, rtgiPreviousRenderSize)) - 0.5));
	vec2 slope = rtgiDepthSlope(view.xyz, mat3(gbufferPreviousModelView) * surface.worldNormal, viewport, gbufferPreviousProjection);
	vec4 geometry;
	// Prefer the sample from the reprojected tile. Try its adjacent samples at an edge.
	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			ivec2 tile = center + ivec2(x, y) * direction;
			if (!rtgiContains(tile, tileSize)) continue;
			if (rtgiHistorySurface(tile, evenFrame, surface.worldNormal, -view.z, slope, pixel, geometry)) {
				historyTile = tile;
				historyCount = geometry.z;
				previousPixel = pixel - rtgiPreviousJitter;
				return true;
			}
		}
	}
	return false;
}

uint rtgiHash(uint value) {
	value = (value ^ (value >> 16u)) * 0x85ebca6bu;
	value = (value ^ (value >> 13u)) * 0xc2b2ae35u;
	return value ^ (value >> 16u);
}

vec3 rtgiDirection(ivec2 tile, vec3 normal) {
	// The pack's cloud noise is spatially smooth. Independent phases keep nearby
	// rays from converging to the same direction across an entire wall.
	uint seed = uint(tile.x) + uint(tile.y) * 65536u;
	uvec2 bits = uvec2(rtgiHash(seed), rtgiHash(seed ^ 0x9e3779b9u));
	vec2 phase = vec2(bits >> 8u) * (1.0 / 16777216.0);
	vec2 samplePoint = fract(phase + vec2(0.75487767, 0.56984029) * float(frameCounter % 4096));
	float radius = sqrt(samplePoint.x);
	float phi = 6.283185307 * samplePoint.y;
	vec3 axis = abs(normal.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
	vec3 tangent = normalize(cross(axis, normal));
	vec3 bitangent = cross(normal, tangent);
	return tangent * (radius * cos(phi)) + bitangent * (radius * sin(phi))
		+ normal * sqrt(1.0 - samplePoint.x);
}

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
	if (evenFrame) {
		imageStore(rtgiSurface0, tile, surface);
		imageStore(rtgiHistory0, tile, lighting);
	} else {
		imageStore(rtgiSurface1, tile, surface);
		imageStore(rtgiHistory1, tile, lighting);
	}
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
		return;
	}

	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		float visibility = 1.0;
		if (surface.blockLightmap > 0.05) {
			vec3 packedNormal = texelFetch(colortex8, pixel, 0).xyz;
			vec3 normal = normalize(vec3(decodeVec2(packedNormal.x).y, decodeVec2(packedNormal.y).y,
				decodeVec2(packedNormal.z).y) * 2.0 - 1.0);
			vec3 playerPosition = (gbufferModelViewInverse * vec4(surface.viewPosition, 1.0)).xyz;
			visibility = rtgiLocalLightVisibility(playerPosition, normal);
		}
		imageStore(rtgiBlockVisibility, tile, vec4(visibility));
	#endif

	bool historyAvailable = rtgiHistoryAvailable(renderSize);

	RtgiSurface hit;
	ivec2 historyTile;
	float historyCount;
	vec2 previousPixel;
	float hitDistance;
	vec3 direction = rtgiDirection(tile, surface.worldNormal);
	bool screenHit = rtgiTrace(surface, direction, pixel, renderSize, viewport, jitter, hit, hitDistance);
	vec4 sampleLighting = vec4(0.0);
	// Reuse the direct lighting recorded by the previous composite pass.
	bool hasScreenLight = false;
	if (screenHit) {
		sampleLighting.a = (1.0 - smoothstep(0.16, 2.0, hitDistance));
		if (historyAvailable && rtgiReproject(hit, viewport, tileSize, evenFrame, historyTile, historyCount, previousPixel)) {
			vec4 direct = imageLoad(rtgiLight, historyTile);
			hasScreenLight = direct.a > 0.0;
			sampleLighting.rgb = max(direct.rgb, vec3(0.0));
		}
	}
	if (!hasScreenLight) sampleLighting.rgb = rtgiWorldBounce(surface.viewPosition, surface.worldNormal, direction);

	vec4 previousLighting = vec4(0.0);
	float sampleCount = 1.0;
	if (historyAvailable && rtgiReproject(surface, viewport, tileSize, evenFrame, historyTile, historyCount, previousPixel)) {
		previousLighting = evenFrame ? imageLoad(rtgiHistory1, historyTile) : imageLoad(rtgiHistory0, historyTile);
		vec2 currentPixel = vec2(pixel) + 0.5 - jitter;
		float screenMotion = length(currentPixel - previousPixel);
		sampleCount += min(historyCount, mix(15.0, 2.0, smoothstep(1.0, 10.0, screenMotion)));
	}

	vec4 geometry = vec4(rtgiEncodeNormal(surface.worldNormal), sampleCount, -surface.viewPosition.z);
	// Keep contact occlusion responsive when nearby geometry changes.
	vec2 sampleWeight = 1.0 / vec2(sampleCount, min(sampleCount, 8.0));
	vec4 lighting = mix(previousLighting, sampleLighting, sampleWeight.xxxy);
	rtgiStoreTile(tile, evenFrame, geometry, lighting);
}

#else

const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}

#endif
