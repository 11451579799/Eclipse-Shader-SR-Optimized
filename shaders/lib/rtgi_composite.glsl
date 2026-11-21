bool rtgiIsTileOrigin(ivec2 pixel, ivec2 renderSize, ivec2 tileSize) {
	ivec2 tile = pixel / rtgiSampleStride();
	return rtgiContains(tile, tileSize) && all(equal(pixel, rtgiTilePixel(tile, renderSize)));
}

void rtgiWriteDirectLight(ivec2 tile, vec4 lighting) {
	imageStore(rtgiLight, tile, lighting);
}

vec4 rtgiGuideGather(vec2 uv, int channel, bool evenFrame) {
	// Gather has a constant component operand. Keep the calls explicit so
	// this remains valid on GLSL compilers that do not inline functions.
	if (channel == 0) return evenFrame ? textureGather(texRtgiSurface0, uv, 0) : textureGather(texRtgiSurface1, uv, 0);
	if (channel == 1) return evenFrame ? textureGather(texRtgiSurface0, uv, 1) : textureGather(texRtgiSurface1, uv, 1);
	if (channel == 2) return evenFrame ? textureGather(texRtgiSurface0, uv, 2) : textureGather(texRtgiSurface1, uv, 2);
	return evenFrame ? textureGather(texRtgiSurface0, uv, 3) : textureGather(texRtgiSurface1, uv, 3);
}

vec4 rtgiUpsample(ivec2 pixel, ivec2 renderSize, ivec2 tileSize, vec3 normal, vec3 viewPos
	#ifdef ECLIPSE_RTGI_WORLD
		, out float worldSkyWeight
	#endif
	#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
		, out vec4 directLight, out float directWeightSum
	#endif
) {
	int stride = rtgiSampleStride();
	ivec2 center = min(pixel / stride, tileSize - 1);
	ivec2 direction = ivec2(rtgiOctSign(vec2(pixel - rtgiTilePixel(center, renderSize))));
	float viewDepth = -viewPos.z;
	vec2 slope = rtgiDepthSlope(viewPos, mat3(gbufferModelView) * normal, rtgiViewportSize(), gbufferProjection);
	float depthTolerance = rtgiDepthTolerance(viewDepth);
	bool evenFrame = rtgiEvenFrame();
	ivec2 outputSize = textureSize(texRtgiDenoised, 0);
	vec4 sum = vec4(0.0);
	float weightSum = 0.0;
	#ifdef ECLIPSE_RTGI_WORLD
		worldSkyWeight = 0.0;
	#endif
	#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
		directLight = vec4(0.0);
		directWeightSum = 0.0;
	#endif

	// A coherent planar footprint can share one bilinear texture sample
	// per lighting signal. Keep the bilateral path at geometry boundaries.
	vec2 lattice = vec2(pixel - ivec2(stride / 2)) / float(stride);
	ivec2 lower = ivec2(floor(lattice));
	if (rtgiContains(lower, tileSize) && rtgiContains(lower + 1, tileSize)
		&& all(lessThan((lower + 1) * stride + stride / 2, renderSize))) {
		vec2 guideUV = (vec2(lower) + 1.0) / vec2(textureSize(texRtgiSurface0, 0));
		vec4 depths = rtgiGuideGather(guideUV, 3, evenFrame);
		vec2 offset = vec2(lower * stride + stride / 2 - pixel);
		vec4 dx = offset.x + float(stride) * vec4(0.0, 1.0, 1.0, 0.0);
		vec4 dy = offset.y + float(stride) * vec4(1.0, 1.0, 0.0, 0.0);
		vec4 error = abs(viewDepth - depths + depths * (dx * slope.x + dy * slope.y));
		if (all(greaterThan(depths, vec4(0.0))) && all(lessThan(error, vec4(0.022 + viewDepth * 0.001)))) {
			vec2 oct = rtgiEncodeNormal(normal);
			vec4 octX = rtgiGuideGather(guideUV, 0, evenFrame);
			vec4 octY = rtgiGuideGather(guideUV, 1, evenFrame);
			if (all(lessThan(abs(octX - oct.x), vec4(0.085))) && all(lessThan(abs(octY - oct.y), vec4(0.085)))) {
				vec2 sampleUV = (lattice + 0.5) / vec2(outputSize);
				#ifdef ECLIPSE_RTGI_WORLD
					vec4 sources = rtgiGuideGather(guideUV, 2, evenFrame);
					vec2 f = fract(lattice);
					vec4 bilinear = vec4((1.0 - f.x) * f.y, f.x * f.y, f.x * (1.0 - f.y), (1.0 - f.x) * (1.0 - f.y));
					worldSkyWeight = dot(vec4(lessThan(sources, vec4(0.0))), bilinear);
				#endif
				#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
					directLight = textureLod(texRtgiDenoised, sampleUV + vec2(0.0, float(outputSize.y / 2) / outputSize.y), 0.0);
					directWeightSum = 1.0;
				#endif
				return textureLod(texRtgiDenoised, sampleUV, 0.0);
			}
		}
	}

	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			ivec2 tile = center + ivec2(x, y) * direction;
			if (!rtgiContains(tile, tileSize)) continue;

			vec4 surface = evenFrame ? texelFetch(texRtgiSurface0, tile, 0) : texelFetch(texRtgiSurface1, tile, 0);
			vec2 offset = vec2(rtgiTilePixel(tile, renderSize) - pixel);
			if (abs(viewDepth - surface.w) > 0.10 + viewDepth * 0.16) continue;
			float depthError = rtgiDepthError(viewDepth, surface.w, slope, offset);
			float depthWeight = 1.0 - depthError / depthTolerance;
			if (surface.w <= 0.0 || depthWeight <= 0.0) continue;
			float normalWeight = dot(normal, rtgiDecodeNormal(surface.xy));
			if (normalWeight < 0.85) continue;

			vec4 lighting = texelFetch(texRtgiDenoised, tile, 0);
			vec2 distanceInTiles = offset / float(stride);
			float spatialWeight = 1.0 / (1.0 + 4.0 * dot(distanceInTiles, distanceInTiles));
			float weight = spatialWeight * depthWeight * depthWeight * normalWeight;
			sum += lighting * weight;
			weightSum += weight;
			#ifdef ECLIPSE_RTGI_WORLD
				worldSkyWeight += surface.z < 0.0 ? weight : 0.0;
			#endif
			#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
				// Direct shadows are more sensitive to mixing across nearby surfaces.
				float guideWeight = weight * (1.0 - smoothstep(0.02, 0.05 + viewDepth * 0.001, depthError));
				ivec2 samplePixel = tile + ivec2(0, outputSize.y / 2);
				directLight += texelFetch(texRtgiDenoised, samplePixel, 0) * guideWeight;
				directWeightSum += guideWeight;
			#endif
		}
	}

	#ifdef ECLIPSE_RTGI_WORLD
		worldSkyWeight /= max(weightSum, 1e-5);
	#endif
	#ifdef ECLIPSE_RTGI_SOFT_SHADOWS
		directLight /= max(directWeightSum, 1e-5);
	#endif
	return sum / max(weightSum, 1e-5);
}
