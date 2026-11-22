#ifdef ECLIPSE_RTGI_WORLD
	#ifdef ECLIPSE_RTGI_TRACE
		#include "/lib/blocks.glsl"
		#include "/lib/SSBOs.glsl"
		#include "/lib/Shadow_Params.glsl"
		#include "/lib/color_transforms.glsl"

		uniform mat4 shadowProjection;
		#ifndef CUSTOM_MOON_ROTATION
			uniform mat4 shadowModelView;
		#endif
		uniform sampler2D shadowcolor0;
		uniform usampler1D texBlockData;
		#if defined CUSTOM_MOON_ROTATION && LIGHTNING_SHADOWS > 0
			uniform vec4 lightningBoltPosition;
		#endif
	#elif !defined TRANSLUCENT_COLORED_SHADOWS
		uniform sampler2D shadowcolor0;
	#endif
	uniform sampler2D shadowtex0;
	uniform sampler2D shadowtex1;
	#if defined ECLIPSE_RTGI_TRACE && defined IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
		const bool shadowHardwareFiltering = true;
		uniform sampler2DShadow shadowtex0HW;
		#ifdef TRANSLUCENT_COLORED_SHADOWS
			uniform sampler2DShadow shadowtex1HW;
		#endif
	#endif
	#include "/lib/rtgi_voxels.glsl"
	#include "/lib/rtgi_voxel_material.glsl"
	#include "/lib/rtgi_face_cache.glsl"
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		#include "/lib/rtgi_local_lights.glsl"
	#endif

	vec3 rtgiSunDirection() {
		#ifdef CUSTOM_MOON_ROTATION
			return vec3(customShadowMatrixSSBO[0].z, customShadowMatrixSSBO[1].z, customShadowMatrixSSBO[2].z);
		#else
			return vec3(shadowModelView[0].z, shadowModelView[1].z, shadowModelView[2].z);
		#endif
	}

	vec3 rtgiSunVisibility(ivec2 shadowPixel, float reference) {
		float opaqueDepth = texelFetch(shadowtex1, shadowPixel, 0).r;
		if (opaqueDepth <= 0.0 || reference > opaqueDepth) return vec3(0.0);
		#ifdef TRANSLUCENT_COLORED_SHADOWS
			float visibleDepth = texelFetch(shadowtex0, shadowPixel, 0).r;
			if (reference > visibleDepth && visibleDepth < opaqueDepth - 1e-6) {
				vec4 tint = texelFetch(shadowcolor0, shadowPixel, 0);
				return toLinear(tint.rgb) * (1.0 - tint.a);
			}
		#endif
		return vec3(1.0);
	}

	vec3 rtgiFilteredSunVisibility(vec2 uv, ivec2 size, float reference) {
		#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
			float clearVisibility = textureLod(shadowtex0HW, vec3(uv, reference), 0.0);
			#ifdef TRANSLUCENT_COLORED_SHADOWS
				if (clearVisibility >= 1.0) return vec3(1.0);
				float opaqueVisibility = textureLod(shadowtex1HW, vec3(uv, reference), 0.0);
				if (opaqueVisibility <= clearVisibility + 1e-5) return vec3(clearVisibility);
			#else
				return vec3(clearVisibility);
			#endif
		#endif
		// Read the original depth and tint for each texel of a colored edge.
		vec2 raster = uv * vec2(size) - 0.5;
		vec2 blend = fract(raster);
		ivec2 base = ivec2(floor(raster));
		ivec2 first = clamp(base, ivec2(0), size - 1);
		ivec2 last = clamp(base + 1, ivec2(0), size - 1);
		return mix(
			mix(rtgiSunVisibility(first, reference), rtgiSunVisibility(ivec2(last.x, first.y), reference), blend.x),
			mix(rtgiSunVisibility(ivec2(first.x, last.y), reference), rtgiSunVisibility(last, reference), blend.x),
			blend.y);
	}

	vec3 rtgiSunIrradiance(vec3 facePosition, vec3 faceNormal) {
		#ifdef CUSTOM_MOON_ROTATION
			mat4 shadowView = customShadowMatrixSSBO;
		#else
			mat4 shadowView = shadowModelView;
		#endif

		// The positive shadow-view Z axis points toward the mapped light.
		vec3 lightDirection = rtgiSunDirection();
		float incidence = dot(faceNormal, lightDirection);
		if (incidence <= 0.06) return vec3(0.0);

		vec3 lightColor = max(lightSourceColorSSBO / 2400.0, vec3(0.0));
		if (max(lightColor.r, max(lightColor.g, lightColor.b)) < 1e-5) return vec3(0.0);
		vec3 projectionScale = vec3(shadowProjection[0].x, shadowProjection[1].y, shadowProjection[2].z);
		vec3 shadowClip = (shadowView * vec4(facePosition, 1.0)).xyz * projectionScale + shadowProjection[3].xyz;
		vec2 shadowXY = shadowClip.xy;
		float distortion = 1.0;
		#ifdef DISTORT_SHADOWMAP
			distortion = calcDistort(shadowXY);
			shadowXY *= distortion;
		#endif
		vec2 shadowUV = shadowXY * 0.5 + 0.5;
		if (any(lessThan(shadowUV, vec2(0.0))) || any(greaterThanEqual(shadowUV, vec2(1.0)))) return vec3(0.0);

		ivec2 shadowSize = textureSize(shadowtex1, 0);
		float reference = shadowClip.z / 12.0 + 0.5;
		if (reference <= 0.0 || reference >= 1.0) return vec3(0.0);
		// Compare the ray hit to the shadow depth. The surface color comes from
		// the hit voxel, since the nearest shadow texel may belong to a different face.
		float texelWidth = 2.0 / (abs(projectionScale.x) * float(shadowSize.x) * max(distortion, 0.25));
		float worldBias = clamp(0.018 + texelWidth * 0.45 / incidence, 0.018, 0.12);
		float bias = worldBias * abs(projectionScale.z) / 12.0;
		vec3 visibility = rtgiFilteredSunVisibility(shadowUV, shadowSize, reference - bias);
		#ifdef USE_CUSTOM_DIFFUSE_LIGHTING_COLORS
			lightColor = luma(lightColor) * vec3(DIRECTLIGHT_DIFFUSE_R, DIRECTLIGHT_DIFFUSE_G, DIRECTLIGHT_DIFFUSE_B);
		#endif
		return visibility * lightColor * ((incidence * 255.0 - 15.0) / 240.0) * (1.0 - rainStrength);
	}

	vec3 rtgiSkyRadiance() {
		vec3 sky = max(averageSkyCol_CloudsSSBO / 900.0, vec3(0.0));
		#ifdef USE_CUSTOM_DIFFUSE_LIGHTING_COLORS
			sky = luma(sky) * vec3(INDIRECTLIGHT_DIFFUSE_R, INDIRECTLIGHT_DIFFUSE_G, INDIRECTLIGHT_DIFFUSE_B);
		#endif
		return sky * ambient_brightness;
	}

	float rtgiVoxelSkylight(uint material) {
		return max(0.0, (float(material >> 24u) - 1.0) / 254.0);
	}

	vec3 rtgiEscapedSkylight(vec3 direction, float skylight) {
		if (direction.y <= 0.0 || skylight <= 0.35) return vec3(0.0);
		// The ray only covers the nearby voxel volume. Use terrain skylight
		// as a guard against treating long tunnels as open sky.
		float visibility = smoothstep(0.35, 0.85, skylight) * smoothstep(0.0, 0.20, direction.y);
		return rtgiSkyRadiance() * visibility;
	}

	bool rtgiVoxelReceiver(vec3 position, vec3 flatNormal, out ivec3 voxel, out uint id) {
		voxel = ivec3(floor(position - flatNormal * rtgiRayBias));
		id = 0u;
		if (!rtgiVoxelContains(voxel)) return false;
		id = imageLoad(imgVoxelMask, voxel).r;
		return rtgiFullVoxel(id) || (id >= BLOCK_DOOR_N && id <= BLOCK_DOOR_W)
			|| (id >= BLOCK_IRON_DOOR_TOP_N && id <= BLOCK_IRON_DOOR_TOP_W)
			|| id == BLOCK_SLAB_TOP || id == BLOCK_SLAB_BOTTOM
			|| (id >= BLOCK_TRAPDOOR_BOTTOM && id <= BLOCK_STAIRS_TOP_OUTER_S_W)
			|| (id >= 22u && id <= 37u)
			|| (id >= BLOCK_GATE_CLOSED_NS && id <= BLOCK_GATE_OPEN_EW);
	}

	vec3 rtgiDirectIrradiance(vec3 surface, vec3 normal) {
		vec3 light = vec3(0.0);
		#if defined CUSTOM_MOON_ROTATION && LIGHTNING_SHADOWS > 0
			if (lightningBoltPosition.w <= 0.0)
		#endif
		light += rtgiSunIrradiance(surface - rtgiVoxelOffset(), normal);
		#if defined ECLIPSE_RTGI_BLOCK_SHADOWS && defined ECLIPSE_RTGI_TRACE
			vec4 local = rtgiLocalLighting(surface, normal, normal, false);
			// RGB already passed per-light visibility. There is no LPV
			// contribution to replace it at this secondary surface.
			light += local.rgb * rtgiLocalLightCoverage(surface + normal * rtgiRayBias);
		#endif
		return light;
	}

	vec3 rtgiShadeVoxelHit(RtgiVoxelHit hit, vec3 surface, bool useCachedDirect, out vec3 directRadiance) {
		uint material = rtgiVoxelMaterialAt(hit.voxel, hit.normal);
		vec3 albedo = material != 0u ? toLinear(unpackUnorm4x8(material).rgb) : vec3(0.45);
		vec3 directLight;
		vec3 bounce;
		float freshness;
		bool hasDirect = rtgiLoadFace(rtgiFaceKey(hit.voxel, hit.normal, hit.blockId), material, directLight, bounce, freshness);
		if (!useCachedDirect || !hasDirect) directLight = rtgiDirectIrradiance(surface, hit.normal);
		if (freshness < 1.0) {
			float skylight = rtgiVoxelSkylight(material);
			float openness = (pow(skylight, 15.0) * 2.0 + skylight * skylight) / 3.0;
			directLight += rtgiSkyRadiance() * ((1.0 - freshness) * openness * (0.5 + 0.5 * hit.normal.y));
		}
		// Let the material absorb light at each relay. Bound feedback on
		// near-white textures so the approximate cache cannot trap energy.
		directRadiance = albedo * directLight;
		return directRadiance + min(albedo, vec3(0.95)) * bounce;
	}

	vec3 rtgiShadeVoxelHit(RtgiVoxelHit hit, vec3 surface, bool useCachedDirect) {
		vec3 unusedDirect;
		return rtgiShadeVoxelHit(hit, surface, useCachedDirect, unusedDirect);
	}

	int rtgiWorldBounce(vec3 position, vec3 flatNormal, vec3 direction, float skylight, out vec4 lighting,
		out RtgiVoxelHit hit, out vec3 transmission, out vec3 directRadiance, out float rangeWeight) {
		lighting = vec4(0.0);
		if (dot(flatNormal, direction) <= 0.0) return rtgiRayMiss;
		const float nearRange = 12.0;
		// Spend the extra range on sheltered surfaces, where a distant wall
		// can provide most of the incident light through a narrow opening.
		float maxDistance = mix(16.0, nearRange, smoothstep(0.25, 0.75, skylight));
		vec3 origin = position + flatNormal * rtgiRayBias;
		directRadiance = vec3(0.0);
		rangeWeight = 1.0;
		int result = rtgiTraceVoxels(origin, direction, maxDistance, ivec3(-1), hit, transmission);
		if (result != rtgiRayHit) {
			if (result == rtgiRayMiss)
				lighting.rgb = transmission * rtgiEscapedSkylight(direction, skylight);
			return result;
		}

		lighting.a = 1.0 - smoothstep(0.10, 2.0, hit.distance);
		lighting.rgb = transmission * rtgiShadeVoxelHit(hit, origin + direction * hit.distance, true, directRadiance);
		if (hit.distance > nearRange)
			rangeWeight = 1.0 - smoothstep(max(nearRange, maxDistance - 2.0), maxDistance, hit.distance);
		lighting.rgb *= rangeWeight;
		return rtgiRayHit;
	}

	int rtgiWorldBounce(vec3 position, vec3 flatNormal, vec3 direction, float skylight, out vec4 lighting) {
		RtgiVoxelHit hit;
		vec3 transmission, directRadiance;
		float rangeWeight;
		return rtgiWorldBounce(position, flatNormal, direction, skylight, lighting, hit, transmission, directRadiance, rangeWeight);
	}

	#if defined RTGI_REFLECTIONS && !defined ECLIPSE_RTGI_TRACE
		float rtgiTraceReflection(vec3 playerPosition, vec3 flatNormal, vec3 direction, float roughness,
			out RtgiVoxelHit hit, out vec3 hitPosition, out vec3 transmission) {
			if (dot(flatNormal, direction) <= 0.0) return 0.0;
			float coverage = 1.0 - smoothstep(36.0, 44.0, length(playerPosition));
			if (coverage <= 0.0) return 0.0;

			vec3 origin = playerPosition + rtgiVoxelOffset() + flatNormal * rtgiRayBias;
			float maxDistance = mix(16.0, 8.0, smoothstep(0.02, 0.42, roughness));
			if (rtgiTraceVoxels(origin, direction, maxDistance, ivec3(-1), true, hit, transmission) != rtgiRayHit)
				return 0.0;
			hitPosition = origin + hit.distance * direction;
			return coverage * (1.0 - smoothstep(maxDistance * 0.75, maxDistance, hit.distance));
		}

		vec3 rtgiShadeReflection(RtgiVoxelHit hit, vec3 hitPosition, vec3 viewDirection, float receiverRoughness) {
			if (rtgiSolidEmitter(hit.blockId) || rtgiTorch(hit.blockId) || rtgiLantern(hit.blockId))
				return 3.25 * rtgiEmitterIntensity(texelFetch(texBlockData, int(hit.blockId), 0).r);

			vec2 pbr = rtgiVoxelSpecularAt(hit.voxel);
			vec3 lighting = rtgiShadeVoxelHit(hit, hitPosition, true);
			if (pbr.x <= 0.0) return lighting;

			bool conductor = pbr.y >= 229.5 / 255.0;
			uint material = rtgiVoxelMaterialAt(hit.voxel, hit.normal);
			if (material == 0u) return lighting;
			vec3 albedo = toLinear(unpackUnorm4x8(material).rgb);
			const vec3 conductorF0[8] = vec3[8](vec3(0.531, 0.512, 0.496), vec3(0.944, 0.776, 0.373),
				vec3(0.912, 0.914, 0.920), vec3(0.556, 0.555, 0.555), vec3(0.926, 0.721, 0.504),
				vec3(0.632, 0.626, 0.641), vec3(0.679, 0.642, 0.588), vec3(0.962, 0.949, 0.922));
			vec3 f0 = vec3(max(pbr.y, 0.02));
			if (conductor) {
				f0 = pbr.y >= 254.5 / 255.0 ? albedo : conductorF0[int(clamp(pbr.y * 255.0 - 229.5, 0.0, 7.0))];
				// The cache has no directional information. Keep a broad estimate
				// of the reflected scene on rough conductors.
				lighting *= mix(vec3(0.55), f0, 0.65);
			}

			vec3 lightDirection = rtgiSunDirection();
			float noL = dot(hit.normal, lightDirection);
			if (noL <= 0.06) return lighting;
			vec3 halfway = normalize(viewDirection + lightDirection);
			float noH = clamp(dot(hit.normal, halfway), 0.0, 1.0);
			// The primary reflection footprint and the sun's area set a minimum
			// lobe size. A point-sized secondary highlight would alias between rays.
			float roughness = 1.0 - pbr.x;
			float alpha = clamp(roughness * roughness + receiverRoughness * 0.5, 0.10, 1.0);
			float a2 = alpha * alpha;
			float denominator = noH * noH * (a2 - 1.0) + 1.0;
			float distribution = a2 / max(denominator * denominator, 1e-5);
			float noV = max(dot(hit.normal, viewDirection), 0.05);
			float visibility = 0.5 / max(noL * mix(noV, 1.0, alpha) + noV * mix(noL, 1.0, alpha), 0.1);
			float grazing = 1.0 - clamp(dot(viewDirection, halfway), 0.0, 1.0);
			float grazing2 = grazing * grazing;
			vec3 fresnel = mix(f0, vec3(1.0), grazing2 * grazing2 * grazing);
			float lobe = clamp(distribution * visibility * 0.318309886, 0.0, 2.0);
			return lighting + fresnel * lobe * rtgiSunIrradiance(hitPosition - rtgiVoxelOffset(), hit.normal);
		}
	#endif
#endif
