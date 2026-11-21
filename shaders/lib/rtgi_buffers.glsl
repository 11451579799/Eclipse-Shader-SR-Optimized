#include "/lib/rtgi_frame.glsl"

#ifdef ECLIPSE_RTGI_ACTIVE

const float rtgiViewRange = 48.0;

// Iris limits the pack to 16 custom images. Store each history's two
// frame banks in the top and bottom halves of a single image.
ivec2 rtgiHistoryPixel(ivec2 tile, bool evenFrame, ivec2 extent) {
	return tile + ivec2(0, evenFrame ? 0 : extent.y / 2);
}

#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
	vec4 rtgiUnpackDirect(uvec4 sampleData) {
		return vec4(unpackHalf2x16(sampleData.x), unpackHalf2x16(sampleData.y));
	}
	#ifdef ECLIPSE_RTGI_TRACE
		layout(rgba32ui) uniform uimage2D rtgiDirect;
	#elif defined ECLIPSE_RTGI_FILTER
		uniform usampler2D texRtgiDirect;
	#endif
#endif

#ifdef ECLIPSE_RTGI_TRACE
	layout(rgba16f) uniform readonly image2D rtgiLight;
	layout(rgba16f) uniform image2D rtgiHistory;
	layout(rgba16f) uniform image2D rtgiSurface0;
	layout(rgba16f) uniform image2D rtgiSurface1;
#elif defined ECLIPSE_RTGI_FILTER
	layout(rgba16f) uniform readonly image2D rtgiHistory;
	layout(rgba16f) uniform readonly image2D rtgiSurface0;
	layout(rgba16f) uniform readonly image2D rtgiSurface1;
	layout(rgba16f) uniform writeonly image2D rtgiDenoised;
	#ifdef ECLIPSE_RTGI_WIDE_FILTER
		layout(rgba16f) uniform readonly image2D rtgiLight;
	#else
		layout(rgba16f) uniform writeonly image2D rtgiLight;
	#endif
#else
	layout(rgba16f) uniform writeonly image2D rtgiLight;
	uniform sampler2D texRtgiSurface0;
	uniform sampler2D texRtgiSurface1;
	uniform sampler2D texRtgiDenoised;
#endif

int rtgiSampleStride() {
	// Keep the number of diffuse and local shadow rays near 250k samples
	// at common native resolutions. Internal DLSS resolutions use 3×3.
	vec2 size = rtgiViewportSize();
	return max(3, int(ceil(sqrt(size.x * size.y / 280000.0))));
}

ivec2 rtgiTileSize(ivec2 renderSize) {
	int stride = rtgiSampleStride();
	#if defined ECLIPSE_RTGI_TRACE || defined ECLIPSE_RTGI_FILTER
		ivec2 capacity = imageSize(rtgiSurface0);
	#else
		ivec2 capacity = textureSize(texRtgiSurface0, 0);
	#endif
	return min((renderSize + stride - 1) / stride, capacity);
}

ivec2 rtgiTilePixel(ivec2 tile, ivec2 renderSize) {
	int stride = rtgiSampleStride();
	return min(tile * stride + stride / 2, renderSize - 1);
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
