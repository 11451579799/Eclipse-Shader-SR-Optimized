// Six representative face colors for nearby terrain, indexed in the LPV grid.
// Shadow geometry supplies material even when the face is outside the camera.
const int rtgiMaterialSize = 64;

ivec3 rtgiMaterialCell(ivec3 voxel) {
	return voxel - ivec3((int(VoxelSize) - rtgiMaterialSize) / 2);
}

bool rtgiMaterialContains(ivec3 cell) {
	return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, ivec3(rtgiMaterialSize)));
}

ivec3 rtgiMaterialFace(ivec3 cell, vec3 normal) {
	vec3 n = abs(normal);
	int axis = n.x >= max(n.y, n.z) ? 0 : (n.y >= n.z ? 1 : 2);
	int face = axis * 2 + int(normal[axis] < 0.0);
	return cell + ivec3(0, 0, face * rtgiMaterialSize);
}

#ifdef RENDER_SHADOW
	layout(r32ui) uniform uimage3D rtgiVoxelAlbedo;
	uniform sampler2D gtexture;

	void rtgiCaptureVoxelMaterial(ivec3 voxel) {
		ivec3 cell = rtgiMaterialCell(voxel);
		if (!rtgiMaterialContains(cell)) return;
		// Choose the lower UV corner to sample once per quad.
		if (!all(lessThan(gl_MultiTexCoord0.xy, mc_midTexCoord.xy))) return;
		vec4 material = textureLod(gtexture, mc_midTexCoord.xy, 1.0);
		if (material.a < 0.5) return;
		vec3 normal = mat3(shadowModelViewInverse) * (gl_NormalMatrix * gl_Normal);
		uint color = packUnorm4x8(vec4(material.rgb * gl_Color.rgb, 1.0));
		imageAtomicMax(rtgiVoxelAlbedo, rtgiMaterialFace(cell, normal), color);
	}
#else
	uniform usampler3D texRtgiVoxelAlbedo;

	vec3 rtgiVoxelAlbedoAt(ivec3 voxel, vec3 normal) {
		ivec3 cell = rtgiMaterialCell(voxel);
		if (!rtgiMaterialContains(cell)) return vec3(0.45);
		uint color = texelFetch(texRtgiVoxelAlbedo, rtgiMaterialFace(cell, normal), 0).r;
		return color != 0u ? toLinear(unpackUnorm4x8(color).rgb) : vec3(0.45);
	}
#endif
