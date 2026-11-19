#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"
#include "/lib/res_params.glsl"

uniform float viewWidth;
uniform float viewHeight;
uniform int frameCounter;
uniform mat4 gbufferProjectionInverse;

#define ECLIPSE_RTGI_FILTER
#define ECLIPSE_RTGI_WIDE_FILTER
#include "/lib/rtgi_buffers.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

#ifdef ECLIPSE_RTGI_ACTIVE
const vec2 workGroupsRender = vec2(0.33333334, 0.33333334);
uniform mat4 gbufferModelView;
uniform mat4 gbufferProjection;

vec4 rtgiSpatialSurface(ivec2 tile, bool evenFrame) {
	return evenFrame ? imageLoad(rtgiSurface0, tile) : imageLoad(rtgiSurface1, tile);
}

void main() {
	ivec2 renderSize = rtgiRenderSize();
	ivec2 tileSize = rtgiTileSize(renderSize);
	ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
	if (!rtgiContains(tile, tileSize)) return;

	bool evenFrame = rtgiEvenFrame();
	vec4 surface = rtgiSpatialSurface(tile, evenFrame);
	if (surface.w <= 0.0) {
		imageStore(rtgiDenoised, rtgiFilteredPixel(tile), vec4(0.0));
		return;
	}

	vec4 center = imageLoad(rtgiDenoised, tile);
	vec3 normal = rtgiDecodeNormal(surface.xy);
	ivec2 pixel = rtgiTilePixel(tile, renderSize);
	vec2 viewport = rtgiViewportSize();
	vec2 uv = (vec2(pixel) + 0.5 - rtgiJitterPixels()) / viewport;
	vec3 view = (gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, 0.0, 1.0)).xyz;
	vec2 slope = rtgiDepthSlope(view * (-surface.w / view.z),
		mat3(gbufferModelView) * normal, viewport, gbufferProjection);
	float tolerance = rtgiDepthTolerance(surface.w);

	// A second, wider step damps the variance of rare diffuse paths from
	// small openings. Keep contact occlusion at its original resolution.
	const float kernel[3] = float[3](6.0, 4.0, 1.0);
	vec3 lighting = center.rgb * 36.0;
	float sumWeight = 36.0;
	for (int y = -2; y <= 2; ++y) {
		for (int x = -2; x <= 2; ++x) {
			if (x == 0 && y == 0) continue;
			ivec2 tap = tile + ivec2(x, y) * 3;
			if (!rtgiContains(tap, tileSize)) continue;

			vec4 geometry = rtgiSpatialSurface(tap, evenFrame);
			if (geometry.w <= 0.0 || abs(geometry.w - surface.w) > 0.14 + surface.w * 0.24) continue;
			float alignment = dot(normal, rtgiDecodeNormal(geometry.xy));
			if (alignment < 0.93) continue;
			vec2 offset = vec2(rtgiTilePixel(tap, renderSize) - pixel);
			float plane = 1.0 - rtgiDepthError(surface.w, geometry.w, slope, offset) / tolerance;
			if (plane <= 0.0) continue;

			float weight = kernel[abs(x)] * kernel[abs(y)] * plane * plane * alignment;
			lighting += imageLoad(rtgiDenoised, tap).rgb * weight;
			sumWeight += weight;
		}
	}
	imageStore(rtgiDenoised, rtgiFilteredPixel(tile), vec4(lighting / sumWeight, center.a));
}

#else
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
