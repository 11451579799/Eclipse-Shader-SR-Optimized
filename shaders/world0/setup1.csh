#version 430 compatibility

#define OVERWORLD_SHADER
#include "/lib/settings.glsl"

layout(local_size_x = 128) in;

#ifdef ECLIPSE_RTGI_WORLD

#define ECLIPSE_RTGI_RESET
#include "/lib/rtgi_face_cache.glsl"
const ivec3 workGroups = ivec3(512, 1, 1);

void main() {
	rtgiFaces[gl_GlobalInvocationID.x].data.x = 0u;
}

#else
const ivec3 workGroups = ivec3(0, 0, 0);
void main() {}
#endif
