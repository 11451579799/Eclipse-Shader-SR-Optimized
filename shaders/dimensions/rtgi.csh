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

const vec2 workGroupsRender = vec2(0.5, 0.5);

uniform sampler2D depthtex1;
uniform sampler2D colortex1;
uniform sampler2D colortex7;
uniform sampler2D noisetex;
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

struct RtgiSurface {
	vec3 viewPosition;
	vec3 worldNormal;
};

bool rtgiReadSurface(ivec2 pixel, ivec2 renderSize, vec2 jitter, out RtgiSurface surface) {
	float depth = texelFetch(depthtex1, pixel, 0).r;
	if (depth <= 0.0 || depth >= 1.0) return false;

	vec4 data = texelFetch(colortex1, pixel, 0);
	if (!rtgiStaticSurface(decodeVec2(data.w).y) || texelFetch(colortex7, pixel, 0).a > 0.99) return false;

	vec2 uv = (vec2(pixel) + 0.5 - jitter) / vec2(renderSize);
	vec4 view = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	surface.viewPosition = view.xyz / view.w;
	surface.worldNormal = decode(vec2(decodeVec2(data.x).y, decodeVec2(data.y).y));
	return surface.viewPosition.z < 0.0 && surface.viewPosition.z >= -rtgiViewRange;
}

bool rtgiHistoryAvailable(ivec2 renderSize) {
	return rtgiPreviousFrame + 1 == frameCounter
		&& all(equal(rtgiPreviousRenderSize, renderSize))
		&& abs(frameTimeCounter - rtgiPreviousTime) < 0.5
		&& abs(sunElevation - rtgiPreviousSun) < 0.04
		&& abs(rainStrength - rtgiPreviousRain) < 0.12
		&& distance(cameraPosition, previousCameraPosition) < 8.0;
}

bool rtgiReproject(
	RtgiSurface surface, ivec2 tileSize, bool evenFrame, out ivec2 historyTile
) {
	vec3 world = (gbufferModelViewInverse * vec4(surface.viewPosition, 1.0)).xyz;
	world += cameraPosition - previousCameraPosition;
	vec4 view = gbufferPreviousModelView * vec4(world, 1.0);
	vec4 clip = gbufferPreviousProjection * view;
	if (clip.w <= 0.0) return false;

	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	vec2 pixel = uv * vec2(rtgiPreviousRenderSize) + rtgiPreviousJitter;
	if (any(lessThan(pixel, vec2(0.0))) || any(greaterThanEqual(pixel, vec2(rtgiPreviousRenderSize)))) return false;

	historyTile = ivec2(pixel) / 2;
	if (!rtgiContains(historyTile, tileSize)) return false;

	vec4 previous = evenFrame ? imageLoad(rtgiSurface1, historyTile) : imageLoad(rtgiSurface0, historyTile);
	return previous.w > 0.0
		&& abs(previous.w + view.z) <= rtgiDepthTolerance(-view.z)
		&& dot(previous.xyz, surface.worldNormal) >= 0.85;
}

vec3 rtgiDirection(ivec2 tile, vec3 normal) {
	ivec2 noiseSize = max(textureSize(noisetex, 0), ivec2(1));
	vec2 noise = texelFetch(noisetex, tile % noiseSize, 0).rg;
	vec2 samplePoint = fract(noise + vec2(0.75487767, 0.56984029) * float(frameCounter % 4096));
	float radius = sqrt(samplePoint.x);
	float phi = 6.283185307 * samplePoint.y;
	vec3 axis = abs(normal.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
	vec3 tangent = normalize(cross(axis, normal));
	vec3 bitangent = cross(normal, tangent);
	return tangent * (radius * cos(phi)) + bitangent * (radius * sin(phi))
		+ normal * sqrt(1.0 - samplePoint.x);
}

bool rtgiRayDepth(
	vec3 position, ivec2 renderSize, vec2 jitter, out ivec2 pixel, out float gap
) {
	vec4 clip = gbufferProjection * vec4(position, 1.0);
	if (clip.w <= 0.0 || abs(clip.z) > clip.w) return false;
	vec2 raster = (clip.xy / clip.w * 0.5 + 0.5) * vec2(renderSize) + jitter;
	if (any(lessThan(raster, vec2(0.0))) || any(greaterThanEqual(raster, vec2(renderSize)))) return false;
	pixel = ivec2(raster);
	float depth = texelFetch(depthtex1, pixel, 0).r;
	gap = depth >= 1.0 ? -1.0 : -position.z - rtgiLinearDepth(depth);
	return true;
}

bool rtgiTrace(
	RtgiSurface surface, vec3 direction, ivec2 originPixel, ivec2 renderSize, vec2 jitter,
	out RtgiSurface hit
) {
	const float maxDistance = 12.0;
	vec3 viewNormal = normalize(mat3(gbufferModelView) * surface.worldNormal);
	vec3 viewDirection = mat3(gbufferModelView) * direction;
	vec3 origin = surface.viewPosition + viewNormal * 0.08;
	float previousDistance = 0.0;

	for (int stepIndex = 0; stepIndex < RTGI_STEPS; ++stepIndex) {
		float progress = float(stepIndex + 1) / float(RTGI_STEPS);
		float travel = mix(0.18, maxDistance, progress * progress);
		vec3 position = origin + viewDirection * travel;
		ivec2 pixel;
		float gap;
		if (!rtgiRayDepth(position, renderSize, jitter, pixel, gap)) return false;
		if (gap < 0.0 || all(equal(pixel, originPixel))) {
			previousDistance = travel;
			continue;
		}

		float thickness = clamp(-position.z * 0.014, 0.10, 0.35);
		if (gap > thickness) {
			// A coarse crossing can pass a thin surface in one step.
			float front = previousDistance;
			float back = travel;
			for (int refine = 0; refine < 2; ++refine) {
				float middle = (front + back) * 0.5;
				ivec2 candidate;
				float candidateGap;
				if (!rtgiRayDepth(origin + viewDirection * middle, renderSize, jitter, candidate, candidateGap)) return false;
				if (candidateGap < 0.0 || all(equal(candidate, originPixel))) {
					front = middle;
				} else {
					back = middle;
					pixel = candidate;
					gap = candidateGap;
				}
			}
		}

		if (gap > thickness || !rtgiReadSurface(pixel, renderSize, jitter, hit)) return false;
		return distance(hit.viewPosition, surface.viewPosition) >= 0.16
			&& dot(hit.worldNormal, -direction) > 0.05;
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
	ivec2 pixel = tile * 2;
	vec2 jitter = rtgiJitterPixels();
	RtgiSurface surface;
	if (isEyeInWater != 0 || !rtgiReadSurface(pixel, renderSize, jitter, surface)) {
		rtgiStoreTile(tile, evenFrame, vec4(0.0), vec4(0.0));
		return;
	}

	vec4 geometry = vec4(surface.worldNormal, -surface.viewPosition.z);
	if (!rtgiHistoryAvailable(renderSize)) {
		rtgiStoreTile(tile, evenFrame, geometry, vec4(0.0));
		return;
	}

	RtgiSurface hit;
	ivec2 historyTile;
	vec3 sampleLighting = vec3(0.0);
	vec3 direction = rtgiDirection(tile, surface.worldNormal);
	// Reuse the direct lighting recorded by the previous composite pass.
	if (rtgiTrace(surface, direction, pixel, renderSize, jitter, hit)
		&& rtgiReproject(hit, tileSize, evenFrame, historyTile)) {
		vec4 direct = evenFrame ? imageLoad(rtgiLight1, historyTile) : imageLoad(rtgiLight0, historyTile);
		if (direct.a > 0.0) sampleLighting = max(direct.rgb, vec3(0.0));
	}

	vec4 previousLighting = vec4(0.0);
	if (rtgiReproject(surface, tileSize, evenFrame, historyTile)) {
		previousLighting = evenFrame ? imageLoad(rtgiHistory1, historyTile) : imageLoad(rtgiHistory0, historyTile);
		float screenMotion = length(vec2(tile - historyTile));
		previousLighting.a = min(previousLighting.a, mix(7.0, 2.0, smoothstep(1.0, 6.0, screenMotion)));
	}

	float sampleCount = previousLighting.a + 1.0;
	vec3 filtered = mix(previousLighting.rgb, sampleLighting, 1.0 / sampleCount);
	rtgiStoreTile(tile, evenFrame, geometry, vec4(filtered, sampleCount));
}

#else

const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}

#endif
