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
	#ifdef RTGI_REFLECTIONS
		uniform sampler2D specular;
	#endif

	void rtgiCaptureVoxelMaterial(ivec3 voxel, uint blockId) {
		ivec3 cell = rtgiMaterialCell(voxel);
		if (!rtgiMaterialContains(cell)) return;
		// Choose the lower UV corner to sample once per quad.
		if (!all(lessThan(gl_MultiTexCoord0.xy, mc_midTexCoord.xy))) return;
		vec4 material = textureLod(gtexture, mc_midTexCoord.xy, 1.0);
		if (material.a < 0.5) return;
		vec3 normal = mat3(shadowModelViewInverse) * (gl_NormalMatrix * gl_Normal);
		// Reserve zero for an absent face. The alpha byte stores terrain skylight.
		float sky = (1.0 + 254.0 * clamp(gl_MultiTexCoord1.y / 240.0, 0.0, 1.0)) / 255.0;
		vec3 albedo = material.rgb * gl_Color.rgb;
		#ifdef MIRROR_IRON
			if (blockId == 504u) albedo = vec3(1.0);
		#endif
		uint color = packUnorm4x8(vec4(albedo, sky));
		imageAtomicMax(rtgiVoxelAlbedo, rtgiMaterialFace(cell, normal), color);
		#ifdef RTGI_REFLECTIONS
			vec2 pbr = textureLod(specular, mc_midTexCoord.xy, 0.0).rg;
			#ifdef MIRROR_IRON
				if (blockId == 504u) pbr = vec2(1.0);
			#endif
			// One representative LabPBR specular record per block. Store F0 as
			// its original byte so the conductor IDs remain distinct.
			if (pbr.x > 0.0 || pbr.y > 0.0) {
				uint packedSpecular = packUnorm4x8(vec4(pbr, 0.0, 0.0));
				imageAtomicMax(rtgiVoxelAlbedo, cell + ivec3(0, 0, 6 * rtgiMaterialSize), packedSpecular);
			}
		#endif
	}
#else
	uniform usampler3D texRtgiVoxelAlbedo;

	uint rtgiVoxelMaterialAt(ivec3 voxel, vec3 normal) {
		ivec3 cell = rtgiMaterialCell(voxel);
		if (!rtgiMaterialContains(cell)) return 0u;
		return texelFetch(texRtgiVoxelAlbedo, rtgiMaterialFace(cell, normal), 0).r;
	}

	#ifdef RTGI_REFLECTIONS
		vec2 rtgiVoxelSpecularAt(ivec3 voxel) {
			ivec3 cell = rtgiMaterialCell(voxel);
			if (!rtgiMaterialContains(cell)) return vec2(0.0);
			return unpackUnorm4x8(texelFetch(texRtgiVoxelAlbedo, cell + ivec3(0, 0, 6 * rtgiMaterialSize), 0).r).rg;
		}
	#endif
#endif
