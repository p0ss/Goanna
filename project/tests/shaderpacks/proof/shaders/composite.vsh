#version 120
// Exercises the gl_TexCoord[] rewrite and gl_FrontColor.
void main() {
    gl_Position = ftransform();
    gl_TexCoord[0] = gl_MultiTexCoord0;
    gl_FrontColor = vec4(1.0, 1.0, 1.0, 1.0);
}
