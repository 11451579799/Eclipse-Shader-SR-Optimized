#ifdef ECLIPSE_RTGI_WORLD
	#include "/lib/blocks.glsl"
	#include "/lib/SSBOs.glsl"
	#include "/lib/Shadow_Params.glsl"
	#include "/lib/color_transforms.glsl"

	uniform mat4 shadowProjection;
	#ifndef CUSTOM_MOON_ROTATION
		uniform mat4 shadowModelView;
	#endif
	uniform sampler2D shadowtex0;
	uniform sampler2D shadowtex1;
	uniform sampler2D shadowcolor0;
	uniform usampler1D texBlockData;
	#include "/lib/rtgi_voxels.glsl"
	#include "/lib/rtgi_face_cache.glsl"
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		#include "/lib/rtgi_local_lights.glsl"
	#endif
	#if defined CUSTOM_MOON_ROTATION && LIGHTNING_SHADOWS > 0
		uniform vec4 lightningBoltPosition;
	#endif

	vec3 rtgiShadowBounce(vec3 facePosition, vec3 faceNormal, ivec3 voxel, vec3 voxelOffset) {
		#ifdef CUSTOM_MOON_ROTATION
			mat4 shadowView = customShadowMatrixSSBO;
		#else
			mat4 shadowView = shadowModelView;
		#endif

		// The positive shadow-view Z axis points toward the mapped light.
		vec3 lightDirection = vec3(shadowView[0].z, shadowView[1].z, shadowView[2].z);
		float incidence = dot(faceNormal, lightDirection);
		if (incidence <= 0.06) return vec3(0.0);

		vec3 projectionScale = vec3(shadowProjection[0].x, shadowProjection[1].y, shadowProjection[2].z);
		vec3 shadowClip = (shadowView * vec4(facePosition, 1.0)).xyz * projectionScale + shadowProjection[3].xyz;
		vec2 shadowXY = shadowClip.xy;
		#ifdef DISTORT_SHADOWMAP
			shadowXY *= calcDistort(shadowXY);
		#endif
		vec2 shadowUV = shadowXY * 0.5 + 0.5;
		if (any(lessThan(shadowUV, vec2(0.0))) || any(greaterThanEqual(shadowUV, vec2(1.0)))) return vec3(0.0);

		ivec2 shadowSize = textureSize(shadowtex0, 0);
		ivec2 shadowPixel = ivec2(shadowUV * vec2(shadowSize));
		float visibleDepth = texelFetch(shadowtex0, shadowPixel, 0).r;
		float opaqueDepth = texelFetch(shadowtex1, shadowPixel, 0).r;
		if (visibleDepth <= 0.0 || visibleDepth >= 1.0 || abs(visibleDepth - opaqueDepth) > 1e-6) return vec3(0.0);

		// Invert the radial distortion at the actual texel center before checking its surface.
		vec2 sampledXY = (vec2(shadowPixel) + 0.5) / vec2(shadowSize) * 2.0 - 1.0;
		#ifdef DISTORT_SHADOWMAP
			float sampledRadius = length(sampledXY);
			float clipRadius = length(shadowClip.xy);
			for (int iteration = 0; iteration < 3; ++iteration) {
				float argument = clipRadius * b + a;
				float error = clipRadius - sampledRadius * k * log(argument);
				float slope = 1.0 - sampledRadius * k * b / argument;
				clipRadius = max(clipRadius - error / max(slope, 0.1), 0.0);
			}
			sampledXY *= clipRadius / max(sampledRadius, 1e-7);
		#endif
		// The shadow vertex shader divides clip Z by six before the viewport transform.
		vec3 sampledClip = vec3(sampledXY, (visibleDepth * 2.0 - 1.0) * 6.0);
		vec3 sampledView = (sampledClip - shadowProjection[3].xyz) / projectionScale;
		vec3 sampledPosition = transpose(mat3(shadowView)) * (sampledView - shadowView[3].xyz);
		vec3 localPosition = sampledPosition + voxelOffset - vec3(voxel);
		if (any(lessThan(localPosition, vec3(-0.035))) || any(greaterThan(localPosition, vec3(1.035)))) return vec3(0.0);
		if (abs(dot(sampledPosition - facePosition, faceNormal)) > 0.035
			|| distance(sampledPosition, facePosition) > 0.30) return vec3(0.0);

		vec4 surface = texelFetch(shadowcolor0, shadowPixel, 0);
		if (surface.a < 0.99) return vec3(0.0);

		vec3 lightColor = max(lightSourceColorSSBO / 2400.0, vec3(0.0));
		#ifdef USE_CUSTOM_DIFFUSE_LIGHTING_COLORS
			lightColor = luma(lightColor) * vec3(DIRECTLIGHT_DIFFUSE_R, DIRECTLIGHT_DIFFUSE_G, DIRECTLIGHT_DIFFUSE_B);
		#endif
		// The shadow map covers terrain. Fade the unresolved contribution in rain.
		return toLinear(surface.rgb) * lightColor * ((incidence * 255.0 - 15.0) / 240.0) * (1.0 - rainStrength);
	}

	bool rtgiVoxelReceiver(vec3 position, vec3 flatNormal) {
		ivec3 voxel = ivec3(floor(position - flatNormal * rtgiRayBias));
		if (!rtgiVoxelContains(voxel)) return false;
		uint id = imageLoad(imgVoxelMask, voxel).r;
		return rtgiFullVoxel(id) || (id >= BLOCK_DOOR_N && id <= BLOCK_DOOR_W)
			|| id == BLOCK_SLAB_TOP || id == BLOCK_SLAB_BOTTOM
			|| (id >= BLOCK_TRAPDOOR_BOTTOM && id <= BLOCK_STAIRS_TOP_OUTER_S_W);
	}

	int rtgiWorldBounce(vec3 position, vec3 flatNormal, vec3 direction, out vec4 lighting, out vec3 firstBounce) {
		lighting = vec4(0.0);
		firstBounce = vec3(0.0);
		if (dot(flatNormal, direction) <= 0.0) return rtgiRayMiss;
		vec3 origin = position + flatNormal * rtgiRayBias;
		RtgiVoxelHit hit;
		vec3 transmission;
		int result = rtgiTraceVoxels(origin, direction, 12.0, ivec3(-1), hit, transmission);
		if (result != rtgiRayHit) return result;

		lighting.a = 1.0 - smoothstep(0.10, 2.0, hit.distance);
		vec3 surface = origin + direction * hit.distance;
		vec3 albedo;
		vec3 bounce;
		if (!rtgiLoadFace(rtgiFaceKey(hit.voxel, hit.normal, hit.blockId), albedo, bounce)) {
			// A face enters the cache when first seen by the opaque pass.
			albedo = vec3(0.68);
			bounce = vec3(0.0);
		}

		#if defined CUSTOM_MOON_ROTATION && LIGHTNING_SHADOWS > 0
			if (lightningBoltPosition.w <= 0.0)
		#endif
		firstBounce = rtgiShadowBounce(surface - rtgiVoxelOffset(), hit.normal, hit.voxel, rtgiVoxelOffset());
		#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
			// Connect the secondary hit directly to nearby lights, including lights
			// outside the view. Each connection runs its own visibility query.
			vec4 direct = rtgiLocalLighting(surface, hit.normal, hit.normal);
			firstBounce += albedo * direct.rgb * direct.a;
		#endif
		firstBounce *= transmission;
		lighting.rgb = firstBounce + transmission * albedo * bounce * 0.75;
		return rtgiRayHit;
	}
#endif
