#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"

layout(local_size_x = 128) in;

#ifdef ECLIPSE_RTGI_WORLD
const ivec3 workGroups = ivec3(512, 1, 1);
uniform int frameCounter;

#define ECLIPSE_RTGI_CACHE_PUBLISH
#include "/lib/rtgi_face_cache.glsl"

void main() {
	uint slot = gl_GlobalInvocationID.x;
	uint pendingSlot = slot + rtgiFaceCacheSize;
	if (rtgiFaces[pendingSlot].data.x == uint(frameCounter) + 1u) {
		rtgiFaces[slot] = rtgiFaces[pendingSlot];
		rtgiFaceGuides[slot] = rtgiFaceGuides[pendingSlot];
	}
}
#else
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
