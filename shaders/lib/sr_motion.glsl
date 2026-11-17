uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

#if defined DISTANT_HORIZONS
	uniform sampler2D dhDepthTex;
	uniform mat4 dhProjectionInverse;
	uniform mat4 dhPreviousProjection;
	#define SR_LOD_DEPTH dhDepthTex
	#define SR_LOD_PROJECTION_INVERSE dhProjectionInverse
	#define SR_LOD_PREVIOUS_PROJECTION dhPreviousProjection
#elif defined VOXY
	uniform sampler2D vxDepthTexTrans;
	uniform mat4 vxProjInv;
	uniform mat4 vxProjPrev;
	#define SR_LOD_DEPTH vxDepthTexTrans
	#define SR_LOD_PROJECTION_INVERSE vxProjInv
	#define SR_LOD_PREVIOUS_PROJECTION vxProjPrev
#endif

vec2 cameraMotionVector() {
	ivec2 pixel = ivec2(gl_FragCoord.xy);
	float depth = texelFetch(depthtex0, pixel, 0).r;
	if (depth < 0.56) return vec2(0.0); // First-person hand depth range.

	mat4 inverseProjection = gbufferProjectionInverse;
	mat4 previousProjection = gbufferPreviousProjection;
	#ifdef SR_LOD_DEPTH
		if (depth >= 1.0 && all(lessThan(pixel, textureSize(SR_LOD_DEPTH, 0)))) {
			float lodDepth = texelFetch(SR_LOD_DEPTH, pixel, 0).r;
			if (lodDepth < 1.0) {
				depth = lodDepth;
				inverseProjection = SR_LOD_PROJECTION_INVERSE;
				previousProjection = SR_LOD_PREVIOUS_PROJECTION;
			}
		}
	#endif

	vec2 currentUv = (gl_FragCoord.xy - SRJitterOffset) / SRScaledViewportSize;
	vec4 view = inverseProjection * vec4(currentUv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	// Sky follows the camera's rotation only.
	if (depth >= 1.0) view.w = 0.0;
	vec4 world = gbufferModelViewInverse * view;
	world.xyz += (cameraPosition - previousCameraPosition) * world.w;
	vec4 previousClip = previousProjection * (gbufferPreviousModelView * world);
	if (previousClip.w <= 0.0) return vec2(0.0);

	vec2 previousUv = previousClip.xy / previousClip.w * 0.5 + 0.5;
	return clamp(previousUv - currentUv, -1.0, 1.0);
}
