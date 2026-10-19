#include "shaderxlate.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Declarations copied from glslang_c_interface.h / resource_limits_c.h and
// spirv_cross_c.h at ghostty's pinned versions. Only what we call: the
// symbols live in libghostty.a, the headers don't ship with it.

// MARK: glslang

typedef struct glslang_shader_s glslang_shader_t;
typedef struct glslang_program_s glslang_program_t;
typedef struct glslang_resource_s glslang_resource_t;

enum {
    GLSLANG_STAGE_FRAGMENT = 4,
    GLSLANG_SOURCE_GLSL = 1,
    GLSLANG_CLIENT_VULKAN = 1,
    GLSLANG_TARGET_VULKAN_1_2 = (1 << 22) | (2 << 12),
    GLSLANG_TARGET_SPV = 1,
    GLSLANG_TARGET_SPV_1_5 = (1 << 16) | (5 << 8),
    GLSLANG_NO_PROFILE = 1 << 0,
    GLSLANG_MSG_DEFAULT_BIT = 0,
    GLSLANG_MSG_SPV_RULES_BIT = 1 << 3,
    GLSLANG_MSG_VULKAN_RULES_BIT = 1 << 4,
};

typedef struct {
    void *include_system;
    void *include_local;
    void *free_include_result;
} glsl_include_callbacks_t;

typedef struct {
    int language;
    int stage;
    int client;
    int client_version;
    int target_language;
    int target_language_version;
    const char *code;
    int default_version;
    int default_profile;
    int force_default_version_and_profile;
    int forward_compatible;
    int messages;
    const glslang_resource_t *resource;
    glsl_include_callbacks_t callbacks;
    void *callbacks_ctx;
} glslang_input_t;

int glslang_initialize_process(void);
const glslang_resource_t *glslang_default_resource(void);
glslang_shader_t *glslang_shader_create(const glslang_input_t *input);
void glslang_shader_delete(glslang_shader_t *shader);
int glslang_shader_preprocess(glslang_shader_t *shader, const glslang_input_t *input);
int glslang_shader_parse(glslang_shader_t *shader, const glslang_input_t *input);
const char *glslang_shader_get_info_log(glslang_shader_t *shader);
glslang_program_t *glslang_program_create(void);
void glslang_program_delete(glslang_program_t *program);
void glslang_program_add_shader(glslang_program_t *program, glslang_shader_t *shader);
int glslang_program_link(glslang_program_t *program, int messages);
void glslang_program_SPIRV_generate(glslang_program_t *program, int stage);
size_t glslang_program_SPIRV_get_size(glslang_program_t *program);
unsigned int *glslang_program_SPIRV_get_ptr(glslang_program_t *program);
const char *glslang_program_get_info_log(glslang_program_t *program);

// MARK: SPIRV-Cross

typedef struct spvc_context_s *spvc_context;
typedef struct spvc_parsed_ir_s *spvc_parsed_ir;
typedef struct spvc_compiler_s *spvc_compiler;
typedef struct spvc_compiler_options_s *spvc_compiler_options;

enum {
    SPVC_SUCCESS = 0,
    SPVC_BACKEND_MSL = 3,
    SPVC_CAPTURE_MODE_TAKE_OWNERSHIP = 1,
    SPVC_COMPILER_OPTION_MSL_BIT = 0x8000000,
    SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING = 49 | SPVC_COMPILER_OPTION_MSL_BIT,
};

typedef void (*spvc_error_callback)(void *userdata, const char *error);

int spvc_context_create(spvc_context *context);
void spvc_context_destroy(spvc_context context);
void spvc_context_set_error_callback(spvc_context context, spvc_error_callback cb, void *userdata);
int spvc_context_parse_spirv(spvc_context context, const unsigned *spirv, size_t words,
                             spvc_parsed_ir *ir);
int spvc_context_create_compiler(spvc_context context, int backend, spvc_parsed_ir ir,
                                 int mode, spvc_compiler *compiler);
int spvc_compiler_create_compiler_options(spvc_compiler compiler, spvc_compiler_options *options);
int spvc_compiler_options_set_bool(spvc_compiler_options options, int option, unsigned char value);
int spvc_compiler_install_compiler_options(spvc_compiler compiler, spvc_compiler_options options);
int spvc_compiler_compile(spvc_compiler compiler, const char **source);

// MARK: Translation

static char *fail(char **err, const char *stage, const char *log) {
    const char *detail = log ? log : "";
    size_t len = strlen(stage) + strlen(detail) + 3;
    *err = malloc(len);
    snprintf(*err, len, "%s: %s", stage, detail);
    return NULL;
}

// SPIRV-Cross reports through a callback; keep the last message.
static void spvc_error(void *userdata, const char *error) {
    char **last = userdata;
    free(*last);
    *last = strdup(error);
}

// SPIR-V words -> MSL. Decoration bindings keep GLSL `binding = N` as the
// Metal buffer/texture index, so the Swift side knows where to bind.
static char *spirv_to_msl(const unsigned *words, size_t count, char **err) {
    spvc_context ctx;
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) {
        return fail(err, "spirv-cross", "context");
    }

    char *last = NULL;
    spvc_context_set_error_callback(ctx, spvc_error, &last);

    char *msl = NULL;
    spvc_parsed_ir ir;
    spvc_compiler compiler;
    spvc_compiler_options options;
    const char *out;
    if (spvc_context_parse_spirv(ctx, words, count, &ir) == SPVC_SUCCESS
        && spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir,
                                        SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
                                        &compiler) == SPVC_SUCCESS
        && spvc_compiler_create_compiler_options(compiler, &options) == SPVC_SUCCESS
        && spvc_compiler_options_set_bool(
               options, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, 1) == SPVC_SUCCESS
        && spvc_compiler_install_compiler_options(compiler, options) == SPVC_SUCCESS
        && spvc_compiler_compile(compiler, &out) == SPVC_SUCCESS) {
        msl = strdup(out);
    } else {
        fail(err, "spirv-cross", last);
    }

    free(last);
    spvc_context_destroy(ctx);
    return msl;
}

char *glsl_to_msl(const char *glsl, char **err) {
    *err = NULL;

    // Refcounted; ghostty_init already called it, this keeps us honest.
    glslang_initialize_process();

    // Same input ghostty's shadertoy.zig feeds glslang.
    glslang_input_t input = {
        .language = GLSLANG_SOURCE_GLSL,
        .stage = GLSLANG_STAGE_FRAGMENT,
        .client = GLSLANG_CLIENT_VULKAN,
        .client_version = GLSLANG_TARGET_VULKAN_1_2,
        .target_language = GLSLANG_TARGET_SPV,
        .target_language_version = GLSLANG_TARGET_SPV_1_5,
        .code = glsl,
        .default_version = 100,
        .default_profile = GLSLANG_NO_PROFILE,
        .messages = GLSLANG_MSG_DEFAULT_BIT,
        .resource = glslang_default_resource(),
    };

    glslang_shader_t *shader = glslang_shader_create(&input);
    if (!shader) {
        return fail(err, "glslang", "shader");
    }
    if (!glslang_shader_preprocess(shader, &input) || !glslang_shader_parse(shader, &input)) {
        fail(err, "glsl", glslang_shader_get_info_log(shader));
        glslang_shader_delete(shader);
        return NULL;
    }

    glslang_program_t *program = glslang_program_create();
    glslang_program_add_shader(program, shader);

    char *msl = NULL;
    if (glslang_program_link(program, GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT)) {
        glslang_program_SPIRV_generate(program, GLSLANG_STAGE_FRAGMENT);
        msl = spirv_to_msl(glslang_program_SPIRV_get_ptr(program),
                           glslang_program_SPIRV_get_size(program), err);
    } else {
        fail(err, "link", glslang_program_get_info_log(program));
    }

    glslang_program_delete(program);
    glslang_shader_delete(shader);
    return msl;
}
