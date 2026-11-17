void rtgiPublishFrame(ivec2 renderSize) {
	rtgiPreviousRenderSize = renderSize;
	rtgiPreviousJitter = rtgiJitterPixels();
	rtgiPreviousFrame = frameCounter;
	rtgiPreviousTime = frameTimeCounter;
	rtgiPreviousSun = sunElevation;
	rtgiPreviousRain = rainStrength;
}

bool rtgiIsTileOrigin(ivec2 pixel, ivec2 renderSize, ivec2 tileSize) {
	return all(equal(pixel % 2, ivec2(0))) && rtgiContains(pixel, renderSize)
		&& rtgiContains(pixel / 2, tileSize);
}

void rtgiWriteDirectLight(ivec2 tile, vec4 lighting) {
	if (rtgiEvenFrame()) {
		imageStore(rtgiLight0, tile, lighting);
	} else {
		imageStore(rtgiLight1, tile, lighting);
	}
}

vec3 rtgiUpsample(ivec2 pixel, ivec2 tileSize, vec3 normal, float viewDepth) {
	ivec2 first = pixel / 2;
	vec2 subPixel = vec2(pixel % 2) * 0.5;
	float depthTolerance = rtgiDepthTolerance(viewDepth);
	bool evenFrame = rtgiEvenFrame();
	vec3 sum = vec3(0.0);
	float weightSum = 0.0;

	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			ivec2 tile = first + ivec2(x, y);
			float spatialWeight = mix(1.0 - subPixel.x, subPixel.x, float(x))
				* mix(1.0 - subPixel.y, subPixel.y, float(y));
			if (spatialWeight <= 0.0 || !rtgiContains(tile, tileSize)) continue;

			vec4 surface = evenFrame ? imageLoad(rtgiSurface0, tile) : imageLoad(rtgiSurface1, tile);
			float depthWeight = 1.0 - abs(viewDepth - surface.w) / depthTolerance;
			float normalWeight = dot(normal, surface.xyz);
			if (surface.w <= 0.0 || depthWeight <= 0.0 || normalWeight < 0.85) continue;

			vec3 lighting = evenFrame ? imageLoad(rtgiHistory0, tile).rgb : imageLoad(rtgiHistory1, tile).rgb;
			float weight = spatialWeight * depthWeight * depthWeight * normalWeight;
			sum += lighting * weight;
			weightSum += weight;
		}
	}

	return sum / max(weightSum, 1e-5);
}
