#include "/lib/common.glsl"

#ifdef CSH

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;
const vec2 workGroupsRender = vec2(0.5, 0.5);

uniform int frameCounter;
uniform float viewWidth;
uniform float viewHeight;
vec2 view = vec2(viewWidth, viewHeight);
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousProjection;
uniform mat4 gbufferPreviousModelView;
uniform sampler2D colortex8;
layout(rgba16f) uniform image2D colorimg10;
layout(rgba16i) uniform iimage2D colorimg11;

#include "/lib/vx/SSBOs.glsl"
#include "/lib/vx/raytrace.glsl"

uint globalSeed = uint((frameCounter * 100 + gl_GlobalInvocationID.x % 100) * 113 + gl_GlobalInvocationID.y % 113);

uint murmur(uint seed) {
    seed = (seed ^ (seed >> 16)) * 0x85ebca6bu;
    seed = (seed ^ (seed >> 13)) * 0xc2b2ae35u;
    return seed ^ (seed >> 16);
}

uint nextUint() {
    return murmur(globalSeed += 0x9e3779b9u);
}

float nextFloat() {
    return float(nextUint()) / float(uint(0xffffffff));
}

vec3 randomSphereSample() {
	float x1, x2;
	float len2;
	do {
		x1 = nextFloat() * 2 - 1;
		x2 = nextFloat() * 2 - 1;
		len2 = x1 * x1 + x2 * x2;
	} while (len2 >= 1);
	float x3 = sqrt(1 - len2);
	return vec3(
		2 * x1 * x3,
		2 * x2 * x3,
		1 - 2 * len2);
}

float infnorm(vec3 x) {
	return max(max(abs(x.x), abs(x.y)), abs(x.z));
}

#define MAX_LIGHT_COUNT 48

shared int lightCount = 0;
shared ivec4[MAX_LIGHT_COUNT] positions;
shared int[MAX_LIGHT_COUNT] mergeOffsets;

void main() {
	ivec2 readTexelCoord = ivec2(gl_GlobalInvocationID.xy) * 2 + ivec2(frameCounter % 2, frameCounter / 2 % 2);
	ivec2 writeTexelCoord = ivec2(gl_GlobalInvocationID.xy);
	vec4 normalDepthData = texelFetch(colortex8, readTexelCoord, 0);
	ivec3 vxPosFrameOffset = ivec3((floor(previousCameraPosition) - floor(cameraPosition)) * 1.1);
	bool validData = (normalDepthData.a < 1.5 && length(normalDepthData.rgb) > 0.1 && all(lessThan(readTexelCoord, ivec2(view + 0.1))));
	vec3 vxPos = vec3(1000);
	int index = int(gl_LocalInvocationID.x + gl_WorkGroupSize.x * gl_LocalInvocationID.y);
	if (validData) {
		vec4 playerPos = gbufferModelViewInverse * (gbufferProjectionInverse * (vec4((readTexelCoord + 0.5) / view, 1 - normalDepthData.a, 1) * 2 - 1));
		playerPos /= playerPos.w;
		if (gl_LocalInvocationID == gl_WorkGroupSize/2) {
			vec4 prevClipPos = gbufferPreviousProjection * (gbufferPreviousModelView * playerPos);
			prevClipPos /= prevClipPos.w;
		}
		vxPos = playerToVx(playerPos.xyz) + max(0.1, 0.005 * length(playerPos.xyz)) * normalDepthData.xyz;
		vec3 dir = randomSphereSample();
		if (dot(dir, normalDepthData.xyz) < 0) dir *= -1;
		ray_hit_t rayHit0 = raytrace(vxPos, LIGHT_TRACE_LENGTH * dir);
		if (rayHit0.emissive) {
			int lightIndex = atomicAdd(lightCount, 1);
			if (lightIndex < MAX_LIGHT_COUNT) {
				positions[lightIndex] = ivec4(rayHit0.pos - 0.05 * rayHit0.normal + 1000, 1) - ivec4(1000, 1000, 1000, 0);
				mergeOffsets[lightIndex] = 0;
			} else {
				atomicMin(lightCount, MAX_LIGHT_COUNT);
			}
		}
	}
	barrier();
	memoryBarrierShared();
	int oldLightCount = lightCount;
	int mergeOffset = 0;
	ivec4 thisPos;
	int k = index + 1;
	if (index < oldLightCount) {
		thisPos = positions[index];
		while (k < oldLightCount && positions[k].xyz != thisPos.xyz) k++;
		if (k < oldLightCount) {
			atomicAdd(mergeOffsets[k], -1000);
			mergeOffset = 1;
			for (k++; k < oldLightCount; k++) {
				atomicAdd(mergeOffsets[k], 1);
			}
		}
	}
	barrier();
	memoryBarrierShared();
	if (index < oldLightCount) {
		if (mergeOffsets[index] > 0) {
			positions[index - mergeOffsets[index]] = thisPos;
		}
		if (mergeOffset > 0) {
			atomicAdd(lightCount, -1);
		}
	}
	barrier();
	memoryBarrierShared();
	oldLightCount = lightCount;
	barrier();
	memoryBarrierShared();
	ivec4 prevFrameLight = imageLoad(colorimg11, writeTexelCoord);
	bool known = (prevFrameLight.xyz == ivec3(0) || prevFrameLight.w == 0);// || nextUint() % 100 == 0);
	prevFrameLight.xyz += vxPosFrameOffset;
	for (int k = 0; k < oldLightCount; k++) {
		if (prevFrameLight.xyz == positions[k].xyz) {
			known = true;
			break;
		}
	}
	if (!known) {
		int thisLightIndex = atomicAdd(lightCount, 1);
		if (thisLightIndex < MAX_LIGHT_COUNT) {
			positions[thisLightIndex] = ivec4(prevFrameLight.xyz, 0);
		} else {
			atomicMin(lightCount, MAX_LIGHT_COUNT);
		}
	}
	barrier();
	memoryBarrierShared();
	if (lightCount > 0 && validData) {
		uint thisLightIndex = nextUint() % lightCount;
		int mat = readBlockVolume(positions[thisLightIndex].xyz + 0.5);
		int baseIndex = getBaseIndex(mat);
		int emissiveVoxelCount = getEmissiveCount(baseIndex);
		vec3 lightPos = positions[thisLightIndex].xyz + 0.5;
		if (emissiveVoxelCount > 0) {
			int subEmissiveIndex = int(nextUint() % emissiveVoxelCount);
			vec3 localPos = readEmissiveLoc(baseIndex, subEmissiveIndex);
			if (any(lessThan(localPos, vec3(-0.5)))) {
				imageStore(colorimg10, writeTexelCoord, vec4(1, 0, 0, 1));
				lightPos = vec3(-10000);
			}
			localPos += (vec3(nextFloat(), nextFloat(), nextFloat()) - 0.5) / (1<<VOXEL_DETAIL_AMOUNT);
			lightPos = floor(lightPos) + localPos;
		}
		vec3 dir = lightPos - vxPos;
		if (length(dir) < LIGHT_TRACE_LENGTH) {
			float lightBrightness = readLightLevel(vxPosToVxCoords(lightPos)) * 0.1;
			lightBrightness *= lightBrightness;
			float ndotl = max(0, dot(normalize(dir), normalDepthData.xyz)) * lightBrightness;
			ray_hit_t rayHit1 = raytrace(vxPos, (1.0 + 0.1 / length(dir)) * dir);
			vec3 writeColor = lightCount * rayHit1.rayColor.rgb * float(rayHit1.emissive) * ndotl * (1.0 / (length(dir) + 0.1));
			if (length(writeColor) > 0.003 && infnorm(rayHit1.pos - 0.05 * rayHit1.normal - positions[thisLightIndex].xyz - 0.5) < 0.51) {
				positions[thisLightIndex].w = 1;
			} else {
				writeColor = vec3(0);
			}
			imageStore(colorimg10, writeTexelCoord, vec4(writeColor, lightCount));
		}
	} else {
		imageStore(colorimg10, writeTexelCoord, vec4(0, 0, 0, lightCount));
	}
	barrier();
	memoryBarrierShared();
	ivec4 lightPosToStore = (index < lightCount && positions[index].w > 0) ? positions[index] : ivec4(0);
	imageStore(colorimg11, writeTexelCoord, lightPosToStore);
}
#endif

#ifdef CSH_A

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;
const vec2 workGroupsRender = vec2(0.5, 0.5);

uniform int frameCounter;
uniform float viewWidth;
uniform float viewHeight;
vec2 view = vec2(viewWidth, viewHeight);

uniform sampler2D colortex8;
layout(rgba16f) uniform image2D colorimg10;


void main() {
	ivec2 readTexelCoord = ivec2(gl_GlobalInvocationID.xy) * 2 + ivec2(frameCounter % 2, frameCounter / 2 % 2);
	ivec2 writeTexelCoord = ivec2(gl_GlobalInvocationID.xy);
	vec4 normalDepthData = texelFetch(colortex8, readTexelCoord, 0);
	vec4 thisLightData = imageLoad(colorimg10, writeTexelCoord);
	int shareAmount = 1;
	float compareLen = length(thisLightData.xyz);
	vec4[4] aroundNormalDepthData;
	for (int k = 0; k < 4; k++) {
		ivec2 offset = (2*(k/2%2)-1) * ivec2(k%2, (k-1)%2);
		ivec2 offsetLocalCoord = ivec2(gl_LocalInvocationID.xy) + offset;
		aroundNormalDepthData[k] = texelFetch(colortex8, readTexelCoord + 2 * offset, 0);
		if (offsetLocalCoord.x >= 0 &&
			offsetLocalCoord.x < gl_WorkGroupSize.x &&
			offsetLocalCoord.y >= 0 &&
			offsetLocalCoord.y < gl_WorkGroupSize.y &&
			writeTexelCoord.x + offset.x < int(view.x * 0.5 + 0.1) &&
			writeTexelCoord.y + offset.y < int(view.y * 0.5 + 0.1) &&
			length(aroundNormalDepthData[k] - normalDepthData) < 0.1 &&
			length(imageLoad(colorimg10, writeTexelCoord + offset).xyz) <= 0.1 * compareLen
		) {
			shareAmount++;
		}
	}
	imageStore(colorimg10, writeTexelCoord, vec4(thisLightData.xyz, 1.0 / shareAmount));
	thisLightData.xyz /= shareAmount;
	barrier();
	memoryBarrierImage();
	for (int k = 0; k < 4; k++) {
		ivec2 offset = (2*(k/2%2)-1) * ivec2(k%2, (k-1)%2);
		ivec2 offsetLocalCoord = ivec2(gl_LocalInvocationID.xy) + offset;
		vec4 thisColor = imageLoad(colorimg10, writeTexelCoord + offset);
		if (offsetLocalCoord.x >= 0 &&
			offsetLocalCoord.x < gl_WorkGroupSize.x &&
			offsetLocalCoord.y >= 0 &&
			offsetLocalCoord.y < gl_WorkGroupSize.y &&
			writeTexelCoord.x + offset.x < int(view.x * 0.5 + 0.1) &&
			writeTexelCoord.y + offset.y < int(view.y * 0.5 + 0.1) &&
			length(aroundNormalDepthData[k] - normalDepthData) < 0.1 &&
			length(thisColor.xyz) > 10 * compareLen
		) {
			thisLightData.xyz += thisColor.xyz * thisColor.w;
		}
	}
	barrier();
	imageStore(colorimg10, writeTexelCoord, thisLightData);
}

#endif