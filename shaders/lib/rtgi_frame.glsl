#ifdef RTGI
	// Iris recognizes a boolean option through its explicit #ifdef
	// when allocating the images and buffers in shaders.properties.
	#if defined IRIS_FEATURE_CUSTOM_IMAGES && !defined VIVECRAFT
		#define ECLIPSE_RTGI_ACTIVE
	#endif
#endif

#ifdef ECLIPSE_RTGI_ACTIVE

#if defined TAA && !defined ECLIPSE_SR_UPSCALE
	uniform int framemod8;
	#include "/lib/TAA_jitter.glsl"
#endif

layout(std430, binding = 6) buffer RtgiFrameHistory {
	ivec2 rtgiPreviousRenderSize;
	vec2 rtgiPreviousJitter;
	int rtgiPreviousFrame;
	float rtgiPreviousTime;
	float rtgiPreviousSun;
	float rtgiPreviousRain;
};

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

vec2 rtgiJitterPixels() {
	#ifdef ECLIPSE_SR_UPSCALE
		return SRJitterOffset;
	#elif defined TAA
		return viewportJitter(framemod8) * 0.5;
	#else
		return vec2(0.0);
	#endif
}

#endif
