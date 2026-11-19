const int rtgiLightCellSize = 8;
const int rtgiLightGridSize = min(128, int(VoxelSize));
const int rtgiLightGridCells = rtgiLightGridSize / rtgiLightCellSize + 1;
const float rtgiLightRange = 16.0;
const float rtgiLightCoverageRadius = 48.0;
const uint rtgiIncompleteLights = 0xffffffffu;
const uint rtgiUntrackedRange = 31u;

ivec3 rtgiLightGridMin() {
	// The cells stay aligned to world blocks as the LPV scrolls past the camera.
	return ivec3((int(VoxelSize) - rtgiLightGridSize) / 2) - (ivec3(floor(cameraPosition)) & 7);
}

vec3 rtgiCellGap(vec3 point, vec3 lo, vec3 hi) {
	return max(max(lo - point, point - hi), 0.0);
}
