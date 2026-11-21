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
	bool samplesWorldSky;
};

void rtgiFilterTap(RtgiFilterGuide guide, ivec2 tile, float spatialWeight,
	inout vec4 total, inout float totalWeight, inout float squaredLumaSum) {
	if (!rtgiContains(tile, guide.tileSize)) return;
	vec4 geometry = rtgiFilterSurface(tile, guide.evenFrame);
	if (geometry.w <= 0.0 || abs(geometry.w - guide.depth) > 0.10 + guide.depth * 0.16) return;
	if ((geometry.z < 0.0) != guide.samplesWorldSky) return;
	vec2 offset = vec2(rtgiTilePixel(tile, guide.renderSize) - guide.pixel);
	float planeWeight = 1.0 - rtgiDepthError(guide.depth, geometry.w, guide.slope, offset) / guide.tolerance;
	float normalWeight = dot(guide.normal, rtgiDecodeNormal(geometry.xy));
	if (planeWeight <= 0.0 || normalWeight < 0.90) return;

	float weight = planeWeight * planeWeight * normalWeight * spatialWeight;
	vec4 light = rtgiFilterHistory(tile, guide.evenFrame);
	float luma = dot(light.rgb, vec3(0.2126, 0.7152, 0.0722));
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
	#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
		// The top half stores indirect RGB and contact occlusion. The bottom
		// half exposes the current direct estimate to hardware interpolation.
		ivec2 directSlot = rtgiHistoryPixel(tile, evenFrame, textureSize(texRtgiDirect, 0));
		vec4 direct = surface.w > 0.0 ? rtgiUnpackDirect(texelFetch(texRtgiDirect, directSlot, 0)) : vec4(0.0);
		imageStore(rtgiDenoised, tile + ivec2(0, imageSize(rtgiDenoised).y / 2), direct);
	#endif
	if (surface.w <= 0.0) {
		imageStore(rtgiLight, tile, vec4(0.0));
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
		surface.w, rtgiDepthTolerance(surface.w), evenFrame, surface.z < 0.0);
	float sampleCount = abs(surface.z);
	const vec3 lumaWeights = vec3(0.2126, 0.7152, 0.0722);
	float centerLuma = dot(center.rgb, lumaWeights);
	vec4 total = vec4(0.0);
	float totalWeight = 0.0;
	float squaredLumaSum = 0.0;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			if (x == 0 && y == 0) continue;
			rtgiFilterTap(guide, tile + ivec2(x, y), x == 0 || y == 0 ? 0.75 : 0.5,
				total, totalWeight, squaredLumaSum);
		}
	}

	// Contact is a short-range signal; reconstruct it using the local footprint.
	float contact = (center.a * 2.0 + total.a) / (2.0 + totalWeight);
	float normalizer = 1.0 / max(totalWeight, 1e-5);
	float meanLuma = dot(total.rgb * normalizer, lumaWeights);
	float variance = max(0.0, squaredLumaSum * normalizer - meanLuma * meanLuma);
	float centerWeight = mix(1.0, 1.65, smoothstep(1.0, 20.0, sampleCount));
	if (totalWeight > 1.0) {
		// Suppress isolated HDR outliers on disocclusion without clamping the
		// accumulated radiance or desaturating the RGB signal.
		float limit = meanLuma + 2.5 * sqrt(variance) + max(0.006, meanLuma * 0.30);
		float robust = min(1.0, limit / max(centerLuma, 1e-5));
		center.rgb *= mix(robust, 1.0, 0.55 * smoothstep(4.0, 20.0, sampleCount));
	}
	if (sampleCount < 10.0 || variance > max(1e-6, 0.045 * meanLuma * meanLuma)) {
		// Wider support in the same pass, with eight taps at two radii.
		int radius = sampleCount < 5.0 ? 4 : 3;
		for (int y = -1; y <= 1; ++y) {
			for (int x = -1; x <= 1; ++x) {
				if (x == 0 && y == 0) continue;
				int spacing = x == 0 || y == 0 ? radius : radius - 1;
				rtgiFilterTap(guide, tile + ivec2(x, y) * spacing, 0.55, total, totalWeight, squaredLumaSum);
			}
		}
	}
	// The trace has finished reading last frame's source lighting. Reuse
	// this image until the opaque composite publishes the next frame's sources.
	imageStore(rtgiLight, tile, vec4((total.rgb + center.rgb * centerWeight) / (totalWeight + centerWeight), contact));
}

#else

const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}

#endif
