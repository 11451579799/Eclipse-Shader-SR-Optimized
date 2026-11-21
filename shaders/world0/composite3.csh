#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"
#include "/lib/res_params.glsl"

uniform float viewWidth;
uniform float viewHeight;
uniform int frameCounter;
uniform float frameTimeCounter;
uniform float sunElevation;
uniform float rainStrength;
#include "/lib/rtgi_frame.glsl"

layout(local_size_x = 1) in;

#ifdef ECLIPSE_RTGI_ACTIVE
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
	// Publish after both reflection passes have read the previous frame.
	rtgiPreviousRenderSize = rtgiRenderSize();
	rtgiPreviousJitter = rtgiJitterPixels();
	rtgiPreviousFrame = frameCounter;
	rtgiPreviousTime = frameTimeCounter;
	rtgiPreviousSun = sunElevation;
	rtgiPreviousRain = rainStrength;
}
#else
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
