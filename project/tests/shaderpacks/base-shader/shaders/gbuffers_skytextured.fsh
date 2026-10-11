#version 120

uniform sampler2D texture;

uniform int isEyeInWater;

varying vec2 texcoord;
varying vec4 color;

void main() {
	if(isEyeInWater != 0) {
		discard;
	}
	
	gl_FragData[0] = texture2D(texture, texcoord) * color;
}