#ifdef RTGI
	#ifdef IRIS_FEATURE_CUSTOM_IMAGES
		#define ECLIPSE_RTGI_ACTIVE
	#endif
#endif

#ifdef ECLIPSE_RTGI_ACTIVE

#if defined TAA && !defined ECLIPSE_SR_UPSCALE
	uniform int framemod8;
	#include "/lib/TAA_jitter.glsl"
#endif

const float rtgiViewRange = 48.0;

layout(std430, binding = 6) buffer RtgiFrameHistory {
	ivec2 rtgiPreviousRenderSize;
	vec2 rtgiPreviousJitter;
	int rtgiPreviousFrame;
	float rtgiPreviousTime;
	float rtgiPreviousSun;
	float rtgiPreviousRain;
};

#ifdef ECLIPSE_RTGI_TRACE
	layout(rgba16f) uniform readonly image2D rtgiLight0;
	layout(rgba16f) uniform readonly image2D rtgiLight1;
	layout(rgba16f) uniform image2D rtgiHistory0;
	layout(rgba16f) uniform image2D rtgiHistory1;
	layout(rgba16f) uniform image2D rtgiSurface0;
	layout(rgba16f) uniform image2D rtgiSurface1;
#else
	layout(rgba16f) uniform writeonly image2D rtgiLight0;
	layout(rgba16f) uniform writeonly image2D rtgiLight1;
	layout(rgba16f) uniform readonly image2D rtgiHistory0;
	layout(rgba16f) uniform readonly image2D rtgiHistory1;
	layout(rgba16f) uniform readonly image2D rtgiSurface0;
	layout(rgba16f) uniform readonly image2D rtgiSurface1;
#endif

ivec2 rtgiRenderSize() {
	#ifdef ECLIPSE_SR_UPSCALE
		return ivec2(SRScaledViewportSize);
	#else
		return ivec2(floor(vec2(viewWidth, viewHeight) * RENDER_SCALE + 0.5));
	#endif
}

ivec2 rtgiTileSize(ivec2 renderSize) {
	return min((renderSize + 1) / 2, imageSize(rtgiSurface0));
}

vec2 rtgiJitterPixels() {
	#ifdef ECLIPSE_SR_UPSCALE
		return SRJitterOffset;
	#elif defined TAA
		return viewportJitter(framemod8) * 0.5;
	#else
		return vec2(0.0);
	#endif
}

bool rtgiContains(ivec2 pixel, ivec2 size) {
	return all(greaterThanEqual(pixel, ivec2(0))) && all(lessThan(pixel, size));
}

bool rtgiEvenFrame() {
	return (frameCounter & 1) == 0;
}

float rtgiLinearDepth(float depth) {
	vec2 viewZW = gbufferProjectionInverse[2].zw * (depth * 2.0 - 1.0)
		+ gbufferProjectionInverse[3].zw;
	return -viewZW.x / viewZW.y;
}

bool rtgiStaticSurface(float mask) {
	return abs(mask - 0.45) >= 0.01  // entities
		&& abs(mask - 0.50) >= 0.01 // lightning
		&& abs(mask - 0.55) >= 0.01 // leaves
		&& abs(mask - 0.60) >= 0.01 // grass
		&& abs(mask - 0.75) >= 0.01 // hand
		&& abs(mask - 0.80) >= 0.01 // shader grass
		&& abs(mask - 0.85) >= 0.01 // particles
		&& abs(mask - 0.90) >= 0.01; // glow item frame
}

float rtgiDepthTolerance(float viewDepth) {
	return clamp(viewDepth * 0.015, 0.08, 0.45);
}

#endif
