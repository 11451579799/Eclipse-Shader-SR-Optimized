const int rtgiLightCellSize = 8;
const int rtgiLightGridSize = min(128, int(VoxelSize));
const int rtgiLightGridCells = rtgiLightGridSize / rtgiLightCellSize + 1;
const float rtgiLightRange = 16.0;
const float rtgiLightCoverageRadius = 48.0;
const float rtgiLightCellOverlap = 1.0;
const float rtgiLightFallbackFade = 1.0;
// Receiver records keep four lights in the first layer. The flag and spare bits
// identify up to eight unresolved bounds, packed two per additional layer.
const uint rtgiLightRecordFlag = 1u << 31u;
const uint rtgiPackedLightMask = 0x1fffffffu;

ivec3 rtgiLightGridMin() {
	// The cells stay aligned to world blocks as the LPV scrolls past the camera.
	return ivec3((int(VoxelSize) - rtgiLightGridSize) / 2) - (ivec3(floor(cameraPosition)) & 7);
}

vec3 rtgiCellGap(vec3 point, vec3 lo, vec3 hi) {
	return max(max(lo - point, point - hi), 0.0);
}

vec3 rtgiBoxGap(vec3 loA, vec3 hiA, vec3 loB, vec3 hiB) {
	return max(max(loA - hiB, loB - hiA), 0.0);
}

uint rtgiPackLightPosition(ivec3 position) {
	return uint(position.x) | (uint(position.y) << 8u) | (uint(position.z) << 16u);
}

ivec3 rtgiUnpackLightPosition(uint packedPosition) {
	return ivec3(packedPosition & 255u, (packedPosition >> 8u) & 255u, (packedPosition >> 16u) & 255u);
}

ivec3 rtgiEmitterVoxelOffset(uint entry) {
	return ivec3(entry & 7u, (entry >> 3u) & 7u, (entry >> 6u) & 7u);
}
