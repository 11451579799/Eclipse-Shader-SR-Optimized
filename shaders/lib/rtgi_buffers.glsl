#ifdef RTGI
	#if defined IRIS_FEATURE_CUSTOM_IMAGES && !defined VIVECRAFT
		#define ECLIPSE_RTGI_ACTIVE
	#endif
#endif

#ifdef ECLIPSE_RTGI_ACTIVE

#if defined TAA && !defined ECLIPSE_SR_UPSCALE
	uniform int framemod8;
	#include "/lib/TAA_jitter.glsl"
#endif

const float rtgiViewRange = 48.0;
const int rtgiStride = 3;
const int rtgiTileCenter = rtgiStride / 2;

layout(std430, binding = 6) buffer RtgiFrameHistory {
	ivec2 rtgiPreviousRenderSize;
	vec2 rtgiPreviousJitter;
	int rtgiPreviousFrame;
	float rtgiPreviousTime;
	float rtgiPreviousSun;
	float rtgiPreviousRain;
};

#ifdef ECLIPSE_RTGI_TRACE
	layout(rgba16f) uniform readonly image2D rtgiLight;
	layout(rgba16f) uniform image2D rtgiHistory0;
	layout(rgba16f) uniform image2D rtgiHistory1;
	layout(rgba16f) uniform image2D rtgiSurface0;
	layout(rgba16f) uniform image2D rtgiSurface1;
	#ifdef ECLIPSE_RTGI_WORLD
		layout(rgba16f) uniform writeonly image2D rtgiFirstBounce;
	#endif
#elif defined ECLIPSE_RTGI_FILTER
	layout(rgba16f) uniform readonly image2D rtgiHistory0;
	layout(rgba16f) uniform readonly image2D rtgiHistory1;
	layout(rgba16f) uniform readonly image2D rtgiSurface0;
	layout(rgba16f) uniform readonly image2D rtgiSurface1;
	layout(rgba16f) uniform writeonly image2D rtgiDenoised;
#else
	layout(rgba16f) uniform writeonly image2D rtgiLight;
	layout(rgba16f) uniform readonly image2D rtgiSurface0;
	layout(rgba16f) uniform readonly image2D rtgiSurface1;
	layout(rgba16f) uniform readonly image2D rtgiDenoised;
	#ifdef ECLIPSE_RTGI_WORLD
		layout(rgba16f) uniform readonly image2D rtgiFirstBounce;
	#endif
#endif

vec2 rtgiViewportSize() {
	#ifdef ECLIPSE_SR_UPSCALE
		return SRScaledViewportSize;
	#else
		return vec2(viewWidth, viewHeight) * RENDER_SCALE;
	#endif
}

ivec2 rtgiRenderSize() {
	// The scaled fullscreen primitive covers pixel centers strictly inside its edge.
	return ivec2(ceil(rtgiViewportSize() - 0.5));
}

ivec2 rtgiTileSize(ivec2 renderSize) {
	return min((renderSize + rtgiStride - 1) / rtgiStride, imageSize(rtgiSurface0));
}

ivec2 rtgiTilePixel(ivec2 tile, ivec2 renderSize) {
	return min(tile * rtgiStride + rtgiTileCenter, renderSize - 1);
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

vec2 rtgiOctSign(vec2 v) {
	return mix(vec2(-1.0), vec2(1.0), greaterThanEqual(v, vec2(0.0)));
}

vec2 rtgiEncodeNormal(vec3 normal) {
	normal /= dot(abs(normal), vec3(1.0));
	return normal.z >= 0.0 ? normal.xy : (1.0 - abs(normal.yx)) * rtgiOctSign(normal.xy);
}

vec3 rtgiDecodeNormal(vec2 oct) {
	vec3 normal = vec3(oct, 1.0 - abs(oct.x) - abs(oct.y));
	if (normal.z < 0.0) normal.xy = (1.0 - abs(normal.yx)) * rtgiOctSign(normal.xy);
	return normalize(normal);
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

// On a plane, inverse depth is affine in screen coordinates. Account for the
// offset from the reprojected point to the center of its lower-resolution tile.
vec2 rtgiDepthSlope(vec3 viewPosition, vec3 viewNormal, vec2 viewport, mat4 projection) {
	float incidence = dot(viewNormal, viewPosition) / -viewPosition.z;
	if (abs(incidence) < 0.03) return vec2(0.0);
	return 2.0 * viewNormal.xy / (incidence * viewport * vec2(projection[0].x, projection[1].y));
}

float rtgiDepthError(float depth, float tileDepth, vec2 slope, vec2 offset) {
	return abs(tileDepth - depth + tileDepth * dot(slope, offset));
}

#endif
