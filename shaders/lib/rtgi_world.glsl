#if defined LPV_ENABLED && defined IS_LPV_ENABLED && defined MC_GL_ARB_shader_image_load_store && !defined PHOTONICS && !defined PLANET_CURVATURE
	#define ECLIPSE_RTGI_WORLD

	#include "/lib/voxel_common.glsl"
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
	#if defined CUSTOM_MOON_ROTATION && LIGHTNING_SHADOWS > 0
		uniform vec4 lightningBoltPosition;
	#endif

	bool rtgiWorldContains(ivec3 voxel) {
		return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, ivec3(VoxelSize)));
	}

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
#endif

vec3 rtgiWorldBounce(vec3 viewPosition, vec3 worldNormal, vec3 worldDirection) {
	#ifdef ECLIPSE_RTGI_WORLD
		#if defined CUSTOM_MOON_ROTATION && LIGHTNING_SHADOWS > 0
			if (lightningBoltPosition.w > 0.0) return vec3(0.0);
		#endif
		// Keep positions camera-relative, including at large world coordinates.
		vec3 cameraOffset = fract(cameraPosition);
		vec3 voxelOffset = cameraOffset + float(VoxelSize / 2u);
		vec3 playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
		vec3 origin = playerPosition + worldNormal * 0.06;
		vec3 originVoxel = origin + cameraOffset;
		ivec3 voxel = ivec3(floor(originVoxel)) + ivec3(VoxelSize / 2u);
		if (!rtgiWorldContains(voxel)) return vec3(0.0);

		// The DDA enters a new cell at each step, so there is no self-hit in the starting cell.
		ivec3 increment = ivec3(sign(worldDirection));
		vec3 localOrigin = fract(originVoxel);
		vec3 crossingStride = 1.0 / max(abs(worldDirection), vec3(1e-6));
		vec3 crossing = mix(localOrigin, 1.0 - localOrigin, greaterThan(worldDirection, vec3(0.0))) * crossingStride;
		crossing = mix(crossing, vec3(1e6), equal(increment, ivec3(0)));

		for (int stepIndex = 0; stepIndex < 10; ++stepIndex) {
			int axis = crossing.x <= crossing.y && crossing.x <= crossing.z ? 0 : (crossing.y <= crossing.z ? 1 : 2);
			float travel = crossing[axis];
			crossing[axis] += crossingStride[axis];
			voxel[axis] += increment[axis];
			if (!rtgiWorldContains(voxel) || travel > 10.0) break;

			uint blockId = imageLoad(imgVoxelMask, voxel).r;
			if (blockId == 0u) continue;
			// Unknown or transmissive entries stop the approximate trace without supplying radiance.
			if (blockId >= 2000u || (texelFetch(texBlockData, int(blockId), 0).g & 0x00ffffffu) != 0u) break;

			vec3 faceNormal = vec3(0.0);
			faceNormal[axis] = -float(increment[axis]);
			vec3 facePosition = origin + travel * worldDirection;
			return rtgiShadowBounce(facePosition, faceNormal, voxel, voxelOffset);
		}
	#endif
	return vec3(0.0);
}
