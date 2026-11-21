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

vec4 rtgiSpatialSurface(ivec2 tile) {
	return rtgiEvenFrame() ? imageLoad(rtgiSurface0, tile) : imageLoad(rtgiSurface1, tile);
}

void main() {
	ivec2 renderSize = rtgiRenderSize();
	ivec2 tileSize = rtgiTileSize(renderSize);
	ivec2 tile = ivec2(gl_GlobalInvocationID.xy);
	if (!rtgiContains(tile, tileSize)) return;

	vec4 center = imageLoad(rtgiLight, tile);
	vec4 surface = rtgiSpatialSurface(tile);
	if (surface.w <= 0.0) {
		imageStore(rtgiDenoised, tile, vec4(0.0));
		return;
	}

	vec3 normal = rtgiDecodeNormal(surface.xy);
	ivec2 pixel = rtgiTilePixel(tile, renderSize);
	vec2 viewport = rtgiViewportSize();
	vec2 uv = (vec2(pixel) + 0.5 - rtgiJitterPixels()) / viewport;
	vec3 ray = (gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, 0.0, 1.0)).xyz;
	vec2 slope = rtgiDepthSlope(ray * (-surface.w / ray.z), mat3(gbufferModelView) * normal, viewport, gbufferProjection);
	float tolerance = rtgiDepthTolerance(surface.w);

	// Wider, sparse support for low-light diffuse paths. Contact remains in
	// the near filter so it stays attached to the receiving surface.
	float centerLuma = dot(center.rgb, vec3(0.2126, 0.7152, 0.0722));
	float centerWeight = mix(1.5, 3.5, smoothstep(0.04, 0.25, centerLuma));
	centerWeight *= mix(0.5, 1.0, smoothstep(1.0, 12.0, abs(surface.z)));
	vec3 total = center.rgb * centerWeight;
	float weightSum = centerWeight;
	const ivec2 offsets[8] = ivec2[8](ivec2(4, 0), ivec2(-4, 0), ivec2(0, 4), ivec2(0, -4),
		ivec2(3, 3), ivec2(3, -3), ivec2(-3, 3), ivec2(-3, -3));
	for (int i = 0; i < 8; ++i) {
		ivec2 tap = tile + offsets[i];
		if (!rtgiContains(tap, tileSize)) continue;
		vec4 geometry = rtgiSpatialSurface(tap);
		if (geometry.w <= 0.0 || abs(geometry.w - surface.w) > 0.14 + surface.w * 0.24
			|| (geometry.z < 0.0) != (surface.z < 0.0)) continue;
		vec2 offset = vec2(rtgiTilePixel(tap, renderSize) - pixel);
		float plane = 1.0 - rtgiDepthError(surface.w, geometry.w, slope, offset) / tolerance;
		float alignment = dot(normal, rtgiDecodeNormal(geometry.xy));
		if (plane <= 0.0 || alignment < 0.93) continue;
		float historyConfidence = mix(0.5, 1.0, smoothstep(1.0, 12.0, abs(geometry.z)));
		float weight = plane * plane * alignment * historyConfidence;
		total += imageLoad(rtgiLight, tap).rgb * weight;
		weightSum += weight;
	}
	imageStore(rtgiDenoised, tile, vec4(total / weightSum, center.a));
}
#else
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
