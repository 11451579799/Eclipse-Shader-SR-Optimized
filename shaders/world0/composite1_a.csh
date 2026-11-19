#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"
#include "/lib/res_params.glsl"

uniform float viewWidth;
uniform float viewHeight;
uniform int frameCounter;
uniform mat4 gbufferProjectionInverse;

#define ECLIPSE_RTGI_FILTER
#include "/lib/rtgi_buffers.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

#ifdef ECLIPSE_RTGI_ACTIVE

const vec2 workGroupsRender = vec2(0.33333334, 0.33333334);
uniform mat4 gbufferModelView;
uniform mat4 gbufferProjection;

vec4 rtgiFilterSurface(ivec2 tile, bool evenFrame) {
	return evenFrame ? imageLoad(rtgiSurface0, tile) : imageLoad(rtgiSurface1, tile);
}

vec4 rtgiFilterHistory(ivec2 tile, bool evenFrame) {
	return imageLoad(rtgiHistory, rtgiHistoryPixel(tile, evenFrame, imageSize(rtgiHistory)));
}

struct RtgiFilterGuide {
	ivec2 renderSize;
	ivec2 tileSize;
	ivec2 pixel;
	vec3 normal;
	vec2 slope;
	float depth;
	float tolerance;
	bool evenFrame;
};

void rtgiFilterTap(RtgiFilterGuide guide, ivec2 tile, float spatialWeight,
	inout vec3 total, inout float totalWeight, inout float squaredLumaSum) {
	if (!rtgiContains(tile, guide.tileSize)) return;
	vec4 geometry = rtgiFilterSurface(tile, guide.evenFrame);
	if (geometry.w <= 0.0 || abs(geometry.w - guide.depth) > 0.10 + guide.depth * 0.16) return;
	vec2 offset = vec2(rtgiTilePixel(tile, guide.renderSize) - guide.pixel);
	float planeWeight = 1.0 - rtgiDepthError(guide.depth, geometry.w, guide.slope, offset) / guide.tolerance;
	float normalWeight = dot(guide.normal, rtgiDecodeNormal(geometry.xy));
	if (planeWeight <= 0.0 || normalWeight < 0.90) return;

	float weight = planeWeight * planeWeight * normalWeight * spatialWeight;
	vec3 light = rtgiFilterHistory(tile, guide.evenFrame).rgb;
	float luma = dot(light, vec3(0.2126, 0.7152, 0.0722));
	total += light * weight;
	totalWeight += weight;
	squaredLumaSum += luma * luma * weight;
}

void main() {
	ivec2 renderSize = rtgiRenderSize();
	ivec2 tileSize = rtgiTileSize(renderSize);
	ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
	if (!rtgiContains(tile, tileSize)) return;

	bool evenFrame = rtgiEvenFrame();
	vec4 surface = rtgiFilterSurface(tile, evenFrame);
	if (surface.w <= 0.0) {
		imageStore(rtgiDenoised, tile, vec4(0.0));
		return;
	}

	vec4 center = rtgiFilterHistory(tile, evenFrame);
	vec3 normal = rtgiDecodeNormal(surface.xy);
	ivec2 pixel = rtgiTilePixel(tile, renderSize);
	vec2 viewport = rtgiViewportSize();
	vec2 uv = (vec2(pixel) + 0.5 - rtgiJitterPixels()) / viewport;
	vec3 direction = (gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, 0.0, 1.0)).xyz;
	vec2 slope = rtgiDepthSlope(direction * (-surface.w / direction.z),
		mat3(gbufferModelView) * normal, viewport, gbufferProjection);
	RtgiFilterGuide guide = RtgiFilterGuide(renderSize, tileSize, pixel, normal, slope,
		surface.w, rtgiDepthTolerance(surface.w), evenFrame);
	// Use more neighbors after disocclusion, when the temporal estimate is noisiest.
	float centerWeight = mix(1.0, 1.5, clamp((surface.z - 1.0) / 15.0, 0.0, 1.0));
	vec3 total = center.rgb * centerWeight;
	float totalWeight = centerWeight;
	const vec3 lumaWeights = vec3(0.2126, 0.7152, 0.0722);
	float centerLuma = dot(center.rgb, lumaWeights);
	float squaredLumaSum = centerLuma * centerLuma * centerWeight;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			if (x == 0 && y == 0) continue;
			rtgiFilterTap(guide, tile + ivec2(x, y), x == 0 || y == 0 ? 0.75 : 0.5,
				total, totalWeight, squaredLumaSum);
		}
	}

	float meanLuma = dot(total / totalWeight, lumaWeights);
	float variance = squaredLumaSum / totalWeight - meanLuma * meanLuma;
	if (surface.z < 5.0 || variance > max(1e-7, 0.09 * meanLuma * meanLuma)) {
		for (int y = -2; y <= 2; ++y) {
			for (int x = -2; x <= 2; ++x) {
				if (max(abs(x), abs(y)) != 2) continue;
				rtgiFilterTap(guide, tile + ivec2(x, y), 0.35,
					total, totalWeight, squaredLumaSum);
			}
		}
	}
	imageStore(rtgiDenoised, tile, vec4(total / totalWeight, center.a));
}

#else

const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}

#endif
