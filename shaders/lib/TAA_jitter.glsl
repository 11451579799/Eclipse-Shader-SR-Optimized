#ifdef ECLIPSE_SR_UPSCALE
	// Convert the mod's pixel offset into the units used by the projection code.
	vec2 viewportJitter(int frameIndex) {
		return 2.0 * SRJitterOffset;
	}
	vec2 projectionJitter(int frameIndex) {
		return viewportJitter(frameIndex) / RENDER_SCALE;
	}
#else
// swap out jitter pattern to be a 4 frame pattern instead of an 8 frame halton sequence
#if defined RESPONSIVE_TAA || defined DH_TAA_OVERRIDE
	const vec2[4] offsets = vec2[4](
		vec2(-0.125,	-0.875),
		vec2( 0.875,	-0.125),
		vec2( 0.125,	 0.875),
		vec2(-0.875,	 0.125)
	);
#else
	const vec2[8] offsets = vec2[8](
	    vec2( 1.0, -3.0)/8.0,
		vec2(-1.0,  3.0)/8.0,
		vec2( 5.0,  1.0)/8.0,
		vec2(-3.0, -5.0)/8.0,
		vec2(-5.0,  5.0)/8.0,
		vec2(-7.0, -1.0)/8.0,
		vec2( 3.0,  7.0)/8.0,
		vec2( 7.0,  7.0)/8.0
	);
#endif
	vec2 viewportJitter(int frameIndex) {
		return offsets[frameIndex];
	}
	vec2 projectionJitter(int frameIndex) {
		return viewportJitter(frameIndex);
	}
#endif
