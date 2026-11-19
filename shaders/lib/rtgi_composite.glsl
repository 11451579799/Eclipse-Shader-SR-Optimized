void rtgiPublishFrame(ivec2 renderSize) {
	rtgiPreviousRenderSize = renderSize;
	rtgiPreviousJitter = rtgiJitterPixels();
	rtgiPreviousFrame = frameCounter;
	rtgiPreviousTime = frameTimeCounter;
	rtgiPreviousSun = sunElevation;
	rtgiPreviousRain = rainStrength;
}

bool rtgiIsTileOrigin(ivec2 pixel, ivec2 renderSize, ivec2 tileSize) {
	ivec2 tile = pixel / rtgiStride;
	return rtgiContains(tile, tileSize) && all(equal(pixel, rtgiTilePixel(tile, renderSize)));
}

void rtgiWriteDirectLight(ivec2 tile, vec4 lighting) {
	imageStore(rtgiLight, tile, lighting);
}

vec4 rtgiUpsample(ivec2 pixel, ivec2 renderSize, ivec2 tileSize, vec3 normal, vec3 viewPos, out float blockVisibility) {
	ivec2 center = min(pixel / rtgiStride, tileSize - 1);
	ivec2 direction = ivec2(rtgiOctSign(vec2(pixel - rtgiTilePixel(center, renderSize))));
	float viewDepth = -viewPos.z;
	vec2 slope = rtgiDepthSlope(viewPos, mat3(gbufferModelView) * normal, rtgiViewportSize(), gbufferProjection);
	float depthTolerance = rtgiDepthTolerance(viewDepth);
	bool evenFrame = rtgiEvenFrame();
	vec4 sum = vec4(0.0);
	float weightSum = 0.0;
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		float visibilitySum = 0.0;
	#endif

	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			ivec2 tile = center + ivec2(x, y) * direction;
			if (!rtgiContains(tile, tileSize)) continue;

			vec4 surface = evenFrame ? imageLoad(rtgiSurface0, tile) : imageLoad(rtgiSurface1, tile);
			vec2 offset = vec2(rtgiTilePixel(tile, renderSize) - pixel);
			if (abs(viewDepth - surface.w) > 0.10 + viewDepth * 0.16) continue;
			float depthWeight = 1.0 - rtgiDepthError(viewDepth, surface.w, slope, offset) / depthTolerance;
			if (surface.w <= 0.0 || depthWeight <= 0.0) continue;
			float normalWeight = dot(normal, rtgiDecodeNormal(surface.xy));
			if (normalWeight < 0.85) continue;

			vec4 lighting = evenFrame ? imageLoad(rtgiHistory0, tile) : imageLoad(rtgiHistory1, tile);
			vec2 distanceInTiles = offset / float(rtgiStride);
			float spatialWeight = 1.0 / (1.0 + 4.0 * dot(distanceInTiles, distanceInTiles));
			float weight = spatialWeight * depthWeight * depthWeight * normalWeight;
			sum += lighting * weight;
			weightSum += weight;
			#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
				visibilitySum += imageLoad(rtgiBlockVisibility, tile).r * weight;
			#endif
		}
	}

	blockVisibility = 1.0;
	#ifdef ECLIPSE_RTGI_BLOCK_SHADOWS
		if (weightSum > 1e-5) blockVisibility = visibilitySum / weightSum;
	#endif
	return sum / max(weightSum, 1e-5);
}
