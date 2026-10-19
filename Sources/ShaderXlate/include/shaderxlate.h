#ifndef SHADERXLATE_H
#define SHADERXLATE_H

// GLSL fragment shader -> Metal Shading Language, via the glslang and
// SPIRV-Cross copies libghostty already links (ghostty's custom-shader path).
//
//   GLSL ──glslang──▶ SPIR-V ──SPIRV-Cross──▶ MSL
//
// Returns malloc'd MSL, or NULL with a malloc'd message in *err. Caller frees.
char *glsl_to_msl(const char *glsl, char **err);

#endif
