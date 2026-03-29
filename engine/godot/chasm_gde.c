/* engine/godot/chasm_gde.c — Chasm GDExtension plugin.
 *
 * Registers ChasmComponent, a Node subclass that loads a .chasm file,
 * compiles it to a shared library on demand, and hot-reloads it when the
 * file changes — the same mechanism as the Raylib engine, adapted for Godot 4.
 *
 * Lifecycle mapping:
 *   Godot _ready()            → chasm_on_init(ctx)
 *   Godot _process(delta)     → chasm_on_tick(ctx, delta)
 *   Godot _draw()             → chasm_on_draw(ctx)   [if parent is CanvasItem]
 *   node freed / scene change → chasm_on_unload(ctx)
 *   hot-reload                → chasm_reload_migrate(ctx)
 *
 * Build:
 *   make -C engine/godot
 *
 * Or via CLI:
 *   chasm compile --engine godot path/to/script.chasm
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <unistd.h>

#include "chasm_gde_types.h"
#include "../raylib/chasm_rt.h"   /* ChasmCtx, ChasmArena */
#include "../raylib/loader.h"     /* ChasmLoader, chasm_loader_open/reload/close */

/* ---- Arena sizes -------------------------------------------------------- */
#define CHASM_FRAME_SIZE    (1 << 20)   /*  1 MB */
#define CHASM_SCRIPT_SIZE   (4 << 20)   /*  4 MB */
#define CHASM_PERSIST_SIZE  (16 << 20)  /* 16 MB */

/* ---- Notification constants (from Godot) -------------------------------- */
#define NOTIFICATION_READY         13
#define NOTIFICATION_PROCESS       17
#define NOTIFICATION_DRAW          18
#define NOTIFICATION_PREDELETE     1

/* ---- Per-instance data -------------------------------------------------- */
typedef struct {
    GDExtensionObjectPtr  owner;          /* The Godot Node object we extend */
    ChasmCtx              ctx;
    uint8_t              *frame_mem;
    uint8_t              *script_mem;
    uint8_t              *persist_mem;
    ChasmLoader           loader;
    char                  script_path[4096];
    time_t                last_mtime;
} ChasmInstance;

/* Current instance dispatching through Godot API shims (thread-local). */
#if defined(_MSC_VER)
static __declspec(thread) ChasmInstance *g_current_inst;
#else
static __thread ChasmInstance *g_current_inst;
#endif

/* Expose current instance so chasm_godot_shim.h can read it. */
ChasmInstance *chasm_gde_current_inst(void) { return g_current_inst; }

/* ---- GDE function pointers (loaded at startup) -------------------------- */
static GDExtensionInterfaceStringNameNewWithUtf8Chars   gde_sn_new;
static GDExtensionInterfaceStringNewWithUtf8Chars        gde_str_new;
static GDExtensionInterfaceStringToUtf8CharsType         gde_str_to_utf8;
static GDExtensionInterfaceStringDestroyType             gde_str_destroy;
static GDExtensionInterfaceObjectSetInstanceType         gde_obj_set_instance;
static GDExtensionInterfaceObjectGetInstanceType         gde_obj_get_instance;
static GDExtensionInterfaceClassdbConstructObjectType    gde_construct_object;
static GDExtensionInterfaceClassdbGetMethodBindType      gde_get_method_bind;
static GDExtensionInterfaceObjectMethodBindPtrCallType   gde_ptrcall;
static GDExtensionInterfaceClassdbRegisterExtensionClass2Type    gde_register_class;
static GDExtensionInterfaceClassdbRegisterExtensionClassMethodType gde_register_method;
static GDExtensionInterfaceClassdbRegisterExtensionClassPropertyType gde_register_property;
static GDExtensionInterfaceClassdbUnregisterExtensionClassType   gde_unregister_class;

static GDExtensionClassLibraryPtr gde_library;

/* ---- Static StringNames ------------------------------------------------- */
CHASM_SN_DECL(SN_CHASM_COMPONENT);
CHASM_SN_DECL(SN_NODE);
CHASM_SN_DECL(SN_READY);
CHASM_SN_DECL(SN_PROCESS);
CHASM_SN_DECL(SN_DRAW);
CHASM_SN_DECL(SN_SCRIPT_PATH);
CHASM_SN_DECL(SN_SET_SCRIPT_PATH);
CHASM_SN_DECL(SN_GET_SCRIPT_PATH);
CHASM_SN_DECL(SN_COMPILE_SCRIPT);
CHASM_SN_DECL(SN_EMPTY);

/* StringName for the Node2D class (for get_global_position method bind). */
CHASM_SN_DECL(SN_NODE2D);
CHASM_SN_DECL(SN_GET_GLOBAL_POSITION);
CHASM_SN_DECL(SN_SET_GLOBAL_POSITION);
CHASM_SN_DECL(SN_MOVE_AND_SLIDE);
CHASM_SN_DECL(SN_CHARACTER_BODY2D);
CHASM_SN_DECL(SN_EMIT_SIGNAL);
CHASM_SN_DECL(SN_GET_NODE);
CHASM_SN_DECL(SN_NODE_PATH_CLS);
CHASM_SN_DECL(SN_INPUT);
CHASM_SN_DECL(SN_IS_ACTION_PRESSED);
CHASM_SN_DECL(SN_IS_ACTION_JUST_PRESSED);
CHASM_SN_DECL(SN_IS_ACTION_JUST_RELEASED);
CHASM_SN_DECL(SN_GET_AXIS);
CHASM_SN_DECL(SN_GET_VELOCITY);
CHASM_SN_DECL(SN_SET_VELOCITY);

/* Static String for property hint. */
CHASM_STR_DECL(STR_CHASM_HINT);
CHASM_STR_DECL(STR_EMPTY);

/* ---- Godot method binds (resolved once at init) ------------------------ */
static void *bind_node2d_get_global_pos;
static void *bind_node2d_set_global_pos;
static void *bind_charbody2d_move_and_slide;
static void *bind_charbody2d_get_velocity;
static void *bind_charbody2d_set_velocity;
static void *bind_object_emit_signal;
static void *bind_node_get_node;
static void *bind_input_is_action_pressed;
static void *bind_input_is_action_just_pressed;
static void *bind_input_is_action_just_released;
static void *bind_input_get_axis;

/* ---- Forward declarations ---------------------------------------------- */
static void chasm_compile_and_load(ChasmInstance *inst);
static void chasm_poll_reload(ChasmInstance *inst);

/* ---- Helpers ------------------------------------------------------------ */

/* Compare two StringNames (both are static/interned so pointer-equal). */
static int sn_eq(GDExtensionConstStringNamePtr a, const uint8_t *b) {
    return memcmp(a, b, 8) == 0;
}

/* Read a Godot String argument (ptrcall) into a C buffer. */
static void string_to_cstr(GDExtensionConstTypePtr str_ptr, char *buf, size_t bufsz) {
    buf[0] = '\0';
    if (!str_ptr) return;
    GDExtensionInt len = gde_str_to_utf8((GDExtensionConstStringPtr)str_ptr, NULL, 0);
    if (len <= 0 || (size_t)len >= bufsz) return;
    gde_str_to_utf8((GDExtensionConstStringPtr)str_ptr, buf, (GDExtensionInt)bufsz);
}

/* Fill a Godot String return value (ptrcall). */
static void cstr_to_string(const char *cstr, GDExtensionTypePtr r_ret) {
    gde_str_new((GDExtensionUninitializedStringPtr)r_ret, cstr ? cstr : "");
}

/* Get the file modification time, returns 0 on error. */
static time_t file_mtime(const char *path) {
    struct stat st;
    return (stat(path, &st) == 0) ? st.st_mtime : 0;
}

/* Find the chasm compiler binary.
 * Checks CHASM_HOME env var, then PATH via `which chasm`. */
static int find_chasm_bin(char *out, size_t outsz) {
    const char *home = getenv("CHASM_HOME");
    if (home) {
        snprintf(out, outsz, "%s/zig-out/bin/chasm", home);
        if (access(out, X_OK) == 0) return 0;
        /* Try bootstrap binary directly */
        snprintf(out, outsz, "%s/bootstrap/shazam", home);
        if (access(out, X_OK) == 0) return 0;
    }
    /* Fall back to PATH */
    snprintf(out, outsz, "chasm");
    return 0;
}

/* ---- Compilation -------------------------------------------------------- */

static void chasm_compile_and_load(ChasmInstance *inst) {
    if (inst->script_path[0] == '\0') return;

    time_t mtime = file_mtime(inst->script_path);
    if (mtime == 0) {
        fprintf(stderr, "[chasm_gde] script not found: %s\n", inst->script_path);
        return;
    }
    inst->last_mtime = mtime;

    /* Derive output path: /tmp/chasm_godot_<timestamp>.so */
    char out_so[4096];
    snprintf(out_so, sizeof(out_so),
        "%s/chasm_godot_%lld%s",
        "/tmp",
        (long long)mtime,
        CHASM_SCRIPT_EXT
    );

    /* Only recompile if the output doesn't already exist from this mtime. */
    if (access(out_so, F_OK) != 0) {
        char chasm_bin[4096];
        find_chasm_bin(chasm_bin, sizeof(chasm_bin));

        /* chasm compile --engine godot <script.chasm>
         * Writes a .c file, then we cc it to a shared library. */
        char compile_cmd[8192];
        snprintf(compile_cmd, sizeof(compile_cmd),
            "%s compile --engine godot \"%s\" 2>&1",
            chasm_bin, inst->script_path
        );
        fprintf(stderr, "[chasm_gde] compiling: %s\n", inst->script_path);
        int ret = system(compile_cmd);
        if (ret != 0) {
            fprintf(stderr, "[chasm_gde] compile failed (exit %d)\n", ret);
            return;
        }

        /* The CLI writes <script>.c next to the source. Compile it to a .so. */
        char script_c[4096];
        size_t plen = strlen(inst->script_path);
        if (plen > 6 && strcmp(inst->script_path + plen - 6, ".chasm") == 0) {
            memcpy(script_c, inst->script_path, plen - 6);
            strcpy(script_c + plen - 6, ".c");
        } else {
            snprintf(script_c, sizeof(script_c), "%s.c", inst->script_path);
        }

        const char *chasm_home = getenv("CHASM_HOME");
        char inc_godot[4096] = "";
        if (chasm_home) {
            snprintf(inc_godot, sizeof(inc_godot),
                "-I\"%s/engine/godot\"", chasm_home);
        }

        char cc_cmd[8192];
#if defined(__APPLE__)
        snprintf(cc_cmd, sizeof(cc_cmd),
            "cc -dynamiclib -undefined dynamic_lookup -O2 -fPIC "
            "-o \"%s\" \"%s\" %s 2>&1",
            out_so, script_c, inc_godot);
#elif defined(_WIN32)
        snprintf(cc_cmd, sizeof(cc_cmd),
            "cc -shared -O2 -o \"%s\" \"%s\" %s 2>&1",
            out_so, script_c, inc_godot);
#else
        snprintf(cc_cmd, sizeof(cc_cmd),
            "cc -shared -fPIC -O2 -o \"%s\" \"%s\" %s 2>&1",
            out_so, script_c, inc_godot);
#endif
        ret = system(cc_cmd);
        if (ret != 0) {
            fprintf(stderr, "[chasm_gde] cc failed (exit %d)\n", ret);
            return;
        }
    }

    /* Load or hot-reload the compiled shared library. */
    if (inst->loader.handle) {
        inst->loader.on_unload(&inst->ctx);
        if (chasm_loader_reload(&inst->loader, &inst->ctx, out_so) != 0) {
            fprintf(stderr, "[chasm_gde] hot-reload failed: %s\n", out_so);
            return;
        }
        fprintf(stderr, "[chasm_gde] hot-reloaded: %s\n", inst->script_path);
    } else {
        if (chasm_loader_open(&inst->loader, out_so) != 0) {
            fprintf(stderr, "[chasm_gde] load failed: %s\n", out_so);
            return;
        }
        inst->loader.module_init(&inst->ctx);
        inst->loader.on_init(&inst->ctx);
        fprintf(stderr, "[chasm_gde] loaded: %s\n", inst->script_path);
    }
}

static void chasm_poll_reload(ChasmInstance *inst) {
    if (inst->script_path[0] == '\0') return;
    time_t mtime = file_mtime(inst->script_path);
    if (mtime > inst->last_mtime) {
        fprintf(stderr, "[chasm_gde] change detected: %s\n", inst->script_path);
        chasm_compile_and_load(inst);
    }
}

/* ---- Virtual method implementations ------------------------------------ */

static void virt_ready(GDExtensionClassInstancePtr p_inst,
                       const GDExtensionConstTypePtr *p_args,
                       GDExtensionTypePtr r_ret) {
    (void)p_args; (void)r_ret;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    if (inst->script_path[0] == '\0') return;
    chasm_compile_and_load(inst);
}

static void virt_process(GDExtensionClassInstancePtr p_inst,
                         const GDExtensionConstTypePtr *p_args,
                         GDExtensionTypePtr r_ret) {
    (void)r_ret;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    if (!inst->loader.handle) return;

    double delta = *(const double *)p_args[0];

    chasm_poll_reload(inst);

    g_current_inst = inst;
    inst->loader.on_tick(&inst->ctx, delta);
    chasm_clear_frame(&inst->ctx);
    g_current_inst = NULL;
}

static void virt_draw(GDExtensionClassInstancePtr p_inst,
                      const GDExtensionConstTypePtr *p_args,
                      GDExtensionTypePtr r_ret) {
    (void)p_args; (void)r_ret;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    if (!inst->loader.handle) return;

    g_current_inst = inst;
    inst->loader.on_draw(&inst->ctx);
    g_current_inst = NULL;
}

/* ---- get_virtual_func -------------------------------------------------- */

static GDExtensionClassCallVirtual chasm_get_virtual(
    void *p_userdata,
    GDExtensionConstStringNamePtr p_name)
{
    (void)p_userdata;
    if (sn_eq(p_name, SN_READY))   return virt_ready;
    if (sn_eq(p_name, SN_PROCESS)) return virt_process;
    if (sn_eq(p_name, SN_DRAW))    return virt_draw;
    return NULL;
}

/* ---- Notification ------------------------------------------------------ */

static void chasm_notification(GDExtensionClassInstancePtr p_inst,
                                int32_t p_what,
                                GDExtensionBool p_reversed) {
    (void)p_reversed;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    if (p_what == NOTIFICATION_PREDELETE && inst->loader.handle) {
        g_current_inst = inst;
        inst->loader.on_unload(&inst->ctx);
        g_current_inst = NULL;
        chasm_loader_close(&inst->loader);
    }
}

/* ---- Property getter / setter methods ---------------------------------- */

/* set_script_path(path: String) -> void */
static void method_set_script_path(
    void *userdata,
    GDExtensionClassInstancePtr p_inst,
    const GDExtensionConstTypePtr *p_args,
    GDExtensionTypePtr r_ret)
{
    (void)userdata; (void)r_ret;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    string_to_cstr(p_args[0], inst->script_path, sizeof(inst->script_path));
    inst->last_mtime = 0; /* Force recompile on next _ready or explicit call */
}

/* get_script_path() -> String */
static void method_get_script_path(
    void *userdata,
    GDExtensionClassInstancePtr p_inst,
    const GDExtensionConstTypePtr *p_args,
    GDExtensionTypePtr r_ret)
{
    (void)userdata; (void)p_args;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    cstr_to_string(inst->script_path, r_ret);
}

/* compile_script() -> void (call explicitly to force recompile) */
static void method_compile_script(
    void *userdata,
    GDExtensionClassInstancePtr p_inst,
    const GDExtensionConstTypePtr *p_args,
    GDExtensionTypePtr r_ret)
{
    (void)userdata; (void)p_args; (void)r_ret;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    inst->last_mtime = 0;
    chasm_compile_and_load(inst);
}

/* ---- Instance create / free ------------------------------------------- */

static GDExtensionObjectPtr chasm_create(void *p_userdata) {
    (void)p_userdata;

    /* Allocate our extension data. */
    ChasmInstance *inst = calloc(1, sizeof(ChasmInstance));
    if (!inst) return NULL;

    inst->frame_mem   = malloc(CHASM_FRAME_SIZE);
    inst->script_mem  = malloc(CHASM_SCRIPT_SIZE);
    inst->persist_mem = malloc(CHASM_PERSIST_SIZE);
    if (!inst->frame_mem || !inst->script_mem || !inst->persist_mem) {
        free(inst->frame_mem);
        free(inst->script_mem);
        free(inst->persist_mem);
        free(inst);
        return NULL;
    }

    inst->ctx.frame      = (ChasmArena){inst->frame_mem,   0, CHASM_FRAME_SIZE};
    inst->ctx.script     = (ChasmArena){inst->script_mem,  0, CHASM_SCRIPT_SIZE};
    inst->ctx.persistent = (ChasmArena){inst->persist_mem, 0, CHASM_PERSIST_SIZE};

    /* Construct the base Node object via Godot. */
    GDExtensionObjectPtr obj = gde_construct_object(
        (GDExtensionConstStringNamePtr)SN_NODE
    );
    inst->owner = obj;

    /* Bind our extension instance to the Godot object. */
    gde_obj_set_instance(obj,
        (GDExtensionConstStringNamePtr)SN_CHASM_COMPONENT,
        (GDExtensionClassInstancePtr)inst
    );

    return obj;
}

static void chasm_free(void *p_userdata, GDExtensionClassInstancePtr p_inst) {
    (void)p_userdata;
    ChasmInstance *inst = (ChasmInstance *)p_inst;
    if (!inst) return;

    if (inst->loader.handle) {
        chasm_loader_close(&inst->loader);
    }
    free(inst->frame_mem);
    free(inst->script_mem);
    free(inst->persist_mem);
    free(inst);
}

static GDExtensionClassInstancePtr chasm_recreate(void *p_userdata,
                                                    GDExtensionObjectPtr p_obj) {
    (void)p_userdata;
    ChasmInstance *inst = calloc(1, sizeof(ChasmInstance));
    if (!inst) return NULL;

    inst->frame_mem   = malloc(CHASM_FRAME_SIZE);
    inst->script_mem  = malloc(CHASM_SCRIPT_SIZE);
    inst->persist_mem = malloc(CHASM_PERSIST_SIZE);
    if (!inst->frame_mem || !inst->script_mem || !inst->persist_mem) {
        free(inst->frame_mem); free(inst->script_mem);
        free(inst->persist_mem); free(inst);
        return NULL;
    }
    inst->ctx.frame      = (ChasmArena){inst->frame_mem,   0, CHASM_FRAME_SIZE};
    inst->ctx.script     = (ChasmArena){inst->script_mem,  0, CHASM_SCRIPT_SIZE};
    inst->ctx.persistent = (ChasmArena){inst->persist_mem, 0, CHASM_PERSIST_SIZE};
    inst->owner = p_obj;

    gde_obj_set_instance(p_obj,
        (GDExtensionConstStringNamePtr)SN_CHASM_COMPONENT,
        (GDExtensionClassInstancePtr)inst
    );
    return (GDExtensionClassInstancePtr)inst;
}

/* ---- Register helper: method ------------------------------------------ */

static void register_method(
    const char *name_sn,    /* pre-built StringName buffer pointer */
    uint8_t    *sn_buf,
    GDExtensionClassMethodPtrCall ptrcall,
    GDExtensionBool has_return,
    GDExtensionPropertyInfo *ret_info,
    uint32_t arg_count,
    GDExtensionPropertyInfo *arg_infos,
    GDExtensionClassMethodArgumentMetadata *arg_metas
) {
    GDExtensionClassMethodInfo mi = {
        .name                  = (GDExtensionStringNamePtr)sn_buf,
        .method_userdata       = NULL,
        .call_func             = NULL,
        .ptrcall_func          = ptrcall,
        .method_flags          = GDEXTENSION_METHOD_FLAGS_DEFAULT,
        .has_return_value      = has_return,
        .return_value_info     = ret_info,
        .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        .argument_count        = arg_count,
        .arguments_info        = arg_infos,
        .arguments_metadata    = arg_metas,
        .default_argument_count = 0,
        .default_arguments     = NULL,
    };
    (void)name_sn;
    gde_register_method(gde_library,
        (GDExtensionConstStringNamePtr)SN_CHASM_COMPONENT, &mi);
}

/* ---- Initialize (called at SCENE level) -------------------------------- */

static void chasm_gde_initialize(void *userdata,
                                  GDExtensionInitializationLevel p_level) {
    (void)userdata;
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE) return;

    /* --- StringName initialization --- */
    CHASM_SN_INIT(gde_sn_new, SN_CHASM_COMPONENT,   "ChasmComponent");
    CHASM_SN_INIT(gde_sn_new, SN_NODE,               "Node");
    CHASM_SN_INIT(gde_sn_new, SN_READY,              "_ready");
    CHASM_SN_INIT(gde_sn_new, SN_PROCESS,            "_process");
    CHASM_SN_INIT(gde_sn_new, SN_DRAW,               "_draw");
    CHASM_SN_INIT(gde_sn_new, SN_SCRIPT_PATH,        "script_path");
    CHASM_SN_INIT(gde_sn_new, SN_SET_SCRIPT_PATH,    "set_script_path");
    CHASM_SN_INIT(gde_sn_new, SN_GET_SCRIPT_PATH,    "get_script_path");
    CHASM_SN_INIT(gde_sn_new, SN_COMPILE_SCRIPT,     "compile_script");
    CHASM_SN_INIT(gde_sn_new, SN_EMPTY,              "");
    CHASM_SN_INIT(gde_sn_new, SN_NODE2D,             "Node2D");
    CHASM_SN_INIT(gde_sn_new, SN_GET_GLOBAL_POSITION,"get_global_position");
    CHASM_SN_INIT(gde_sn_new, SN_SET_GLOBAL_POSITION,"set_global_position");
    CHASM_SN_INIT(gde_sn_new, SN_MOVE_AND_SLIDE,     "move_and_slide");
    CHASM_SN_INIT(gde_sn_new, SN_CHARACTER_BODY2D,   "CharacterBody2D");
    CHASM_SN_INIT(gde_sn_new, SN_EMIT_SIGNAL,        "emit_signal");
    CHASM_SN_INIT(gde_sn_new, SN_GET_NODE,           "get_node");
    CHASM_SN_INIT(gde_sn_new, SN_NODE_PATH_CLS,      "NodePath");

    CHASM_STR_INIT(gde_str_new, STR_CHASM_HINT, "*.chasm");
    CHASM_STR_INIT(gde_str_new, STR_EMPTY,       "");

    /* --- Resolve method binds for Godot API shims --- */
    bind_node2d_get_global_pos  = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_NODE2D,
        (GDExtensionConstStringNamePtr)SN_GET_GLOBAL_POSITION, 3341600327LL);
    bind_node2d_set_global_pos  = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_NODE2D,
        (GDExtensionConstStringNamePtr)SN_SET_GLOBAL_POSITION, 743155724LL);
    bind_charbody2d_move_and_slide = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_CHARACTER_BODY2D,
        (GDExtensionConstStringNamePtr)SN_MOVE_AND_SLIDE, 2240023801LL);
    bind_object_emit_signal     = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_NODE,
        (GDExtensionConstStringNamePtr)SN_EMIT_SIGNAL, 4047867050LL);
    bind_node_get_node          = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_NODE,
        (GDExtensionConstStringNamePtr)SN_GET_NODE, 2734337346LL);

    /* Additional StringNames */
    CHASM_SN_INIT(gde_sn_new, SN_INPUT,                  "Input");
    CHASM_SN_INIT(gde_sn_new, SN_IS_ACTION_PRESSED,      "is_action_pressed");
    CHASM_SN_INIT(gde_sn_new, SN_IS_ACTION_JUST_PRESSED,  "is_action_just_pressed");
    CHASM_SN_INIT(gde_sn_new, SN_IS_ACTION_JUST_RELEASED, "is_action_just_released");
    CHASM_SN_INIT(gde_sn_new, SN_GET_AXIS,               "get_axis");
    CHASM_SN_INIT(gde_sn_new, SN_GET_VELOCITY,           "get_velocity");
    CHASM_SN_INIT(gde_sn_new, SN_SET_VELOCITY,           "set_velocity");

    /* Input singleton binds */
    bind_input_is_action_pressed     = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_INPUT,
        (GDExtensionConstStringNamePtr)SN_IS_ACTION_PRESSED, 1537749310LL);
    bind_input_is_action_just_pressed = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_INPUT,
        (GDExtensionConstStringNamePtr)SN_IS_ACTION_JUST_PRESSED, 1537749310LL);
    bind_input_is_action_just_released = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_INPUT,
        (GDExtensionConstStringNamePtr)SN_IS_ACTION_JUST_RELEASED, 1537749310LL);
    bind_input_get_axis              = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_INPUT,
        (GDExtensionConstStringNamePtr)SN_GET_AXIS, 2359065225LL);

    /* CharacterBody2D velocity binds */
    bind_charbody2d_get_velocity     = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_CHARACTER_BODY2D,
        (GDExtensionConstStringNamePtr)SN_GET_VELOCITY, 3341600327LL);
    bind_charbody2d_set_velocity     = gde_get_method_bind(
        (GDExtensionConstStringNamePtr)SN_CHARACTER_BODY2D,
        (GDExtensionConstStringNamePtr)SN_SET_VELOCITY, 743155724LL);

    /* --- Build the class creation info --- */
    GDExtensionClassCreationInfo2 ci = {
        .is_virtual              = GDEXTENSION_FALSE,
        .is_abstract             = GDEXTENSION_FALSE,
        .is_exposed              = GDEXTENSION_TRUE,
        .is_runtime              = GDEXTENSION_FALSE,
        .p_native_structure_string = NULL,
        .set_func                = NULL,
        .get_func                = NULL,
        .get_property_list_func  = NULL,
        .free_property_list_func = NULL,
        .property_can_revert_func = NULL,
        .property_get_revert_func = NULL,
        .validate_property_func  = NULL,
        .notification_func       = chasm_notification,
        .to_string_func          = NULL,
        .reference_func          = NULL,
        .unreference_func        = NULL,
        .create_instance_func    = chasm_create,
        .free_instance_func      = chasm_free,
        .recreate_instance_func  = chasm_recreate,
        .get_virtual_func        = chasm_get_virtual,
        .get_virtual_call_data_func = NULL,
        .call_virtual_with_data_func = NULL,
        .get_rid_func            = NULL,
        .class_userdata          = NULL,
    };
    gde_register_class(gde_library,
        (GDExtensionConstStringNamePtr)SN_CHASM_COMPONENT,
        (GDExtensionConstStringNamePtr)SN_NODE,
        &ci);

    /* --- Register set_script_path --- */
    {
        GDExtensionPropertyInfo arg_info = {
            .type        = GDEXTENSION_VARIANT_TYPE_STRING,
            .class_name  = (GDExtensionStringNamePtr)SN_EMPTY,
            .name        = (GDExtensionStringNamePtr)SN_SCRIPT_PATH,
            .hint_string = (GDExtensionStringPtr)STR_EMPTY,
            .hint        = GDEXTENSION_PROPERTY_HINT_NONE,
            .usage       = GDEXTENSION_PROPERTY_USAGE_DEFAULT,
        };
        GDExtensionClassMethodArgumentMetadata meta =
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
        register_method("set_script_path", SN_SET_SCRIPT_PATH,
            method_set_script_path,
            GDEXTENSION_FALSE, NULL,
            1, &arg_info, &meta);
    }

    /* --- Register get_script_path --- */
    {
        GDExtensionPropertyInfo ret_info = {
            .type        = GDEXTENSION_VARIANT_TYPE_STRING,
            .class_name  = (GDExtensionStringNamePtr)SN_EMPTY,
            .name        = (GDExtensionStringNamePtr)SN_SCRIPT_PATH,
            .hint_string = (GDExtensionStringPtr)STR_EMPTY,
            .hint        = GDEXTENSION_PROPERTY_HINT_NONE,
            .usage       = GDEXTENSION_PROPERTY_USAGE_DEFAULT,
        };
        register_method("get_script_path", SN_GET_SCRIPT_PATH,
            method_get_script_path,
            GDEXTENSION_TRUE, &ret_info,
            0, NULL, NULL);
    }

    /* --- Register compile_script --- */
    {
        register_method("compile_script", SN_COMPILE_SCRIPT,
            method_compile_script,
            GDEXTENSION_FALSE, NULL,
            0, NULL, NULL);
    }

    /* --- Register script_path as an @export property --- */
    {
        GDExtensionPropertyInfo prop = {
            .type        = GDEXTENSION_VARIANT_TYPE_STRING,
            .class_name  = (GDExtensionStringNamePtr)SN_EMPTY,
            .name        = (GDExtensionStringNamePtr)SN_SCRIPT_PATH,
            .hint_string = (GDExtensionStringPtr)STR_CHASM_HINT,
            .hint        = GDEXTENSION_PROPERTY_HINT_GLOBAL_FILE,
            .usage       = GDEXTENSION_PROPERTY_USAGE_DEFAULT,
        };
        gde_register_property(gde_library,
            (GDExtensionConstStringNamePtr)SN_CHASM_COMPONENT,
            &prop,
            (GDExtensionConstStringNamePtr)SN_SET_SCRIPT_PATH,
            (GDExtensionConstStringNamePtr)SN_GET_SCRIPT_PATH);
    }

    fprintf(stderr, "[chasm_gde] ChasmComponent registered\n");
}

static void chasm_gde_deinitialize(void *userdata,
                                    GDExtensionInitializationLevel p_level) {
    (void)userdata;
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE) return;
    gde_unregister_class(gde_library,
        (GDExtensionConstStringNamePtr)SN_CHASM_COMPONENT);
}

/* ---- Plugin entry point ------------------------------------------------ */

GDExtensionBool chasm_gde_init(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization)
{
    gde_library = p_library;

    /* Load all required GDE interface functions. */
#define LOAD(type, name) \
    do { \
        type fn = (type)p_get_proc_address(#name); \
        if (!fn) { \
            fprintf(stderr, "[chasm_gde] missing interface: " #name "\n"); \
            return GDEXTENSION_FALSE; \
        } \
        name = fn; \
    } while(0)

    /* Map our local variable names to GDE proc names. */
    gde_sn_new          = (GDExtensionInterfaceStringNameNewWithUtf8Chars)
                            p_get_proc_address("string_name_new_with_utf8_chars");
    gde_str_new         = (GDExtensionInterfaceStringNewWithUtf8Chars)
                            p_get_proc_address("string_new_with_utf8_chars");
    gde_str_to_utf8     = (GDExtensionInterfaceStringToUtf8CharsType)
                            p_get_proc_address("string_to_utf8_chars");
    gde_str_destroy     = (GDExtensionInterfaceStringDestroyType)
                            p_get_proc_address("string_destroy");
    gde_obj_set_instance = (GDExtensionInterfaceObjectSetInstanceType)
                            p_get_proc_address("object_set_instance");
    gde_obj_get_instance = (GDExtensionInterfaceObjectGetInstanceType)
                            p_get_proc_address("object_get_instance");
    gde_construct_object = (GDExtensionInterfaceClassdbConstructObjectType)
                            p_get_proc_address("classdb_construct_object");
    gde_get_method_bind  = (GDExtensionInterfaceClassdbGetMethodBindType)
                            p_get_proc_address("classdb_get_method_bind");
    gde_ptrcall          = (GDExtensionInterfaceObjectMethodBindPtrCallType)
                            p_get_proc_address("object_method_bind_ptrcall");
    gde_register_class   = (GDExtensionInterfaceClassdbRegisterExtensionClass2Type)
                            p_get_proc_address("classdb_register_extension_class2");
    gde_register_method  = (GDExtensionInterfaceClassdbRegisterExtensionClassMethodType)
                            p_get_proc_address("classdb_register_extension_class_method");
    gde_register_property= (GDExtensionInterfaceClassdbRegisterExtensionClassPropertyType)
                            p_get_proc_address("classdb_register_extension_class_property");
    gde_unregister_class = (GDExtensionInterfaceClassdbUnregisterExtensionClassType)
                            p_get_proc_address("classdb_unregister_extension_class");
#undef LOAD

    /* Validate required procs. */
    if (!gde_sn_new || !gde_str_new || !gde_obj_set_instance ||
        !gde_construct_object || !gde_register_class ||
        !gde_register_method || !gde_register_property) {
        fprintf(stderr, "[chasm_gde] missing required GDE interface functions\n");
        return GDEXTENSION_FALSE;
    }

    r_initialization->minimum_initialization_level =
        GDEXTENSION_INITIALIZATION_SCENE;
    r_initialization->userdata    = NULL;
    r_initialization->initialize  = chasm_gde_initialize;
    r_initialization->deinitialize= chasm_gde_deinitialize;

    return GDEXTENSION_TRUE;
}

/* ---- Godot API shim implementations ------------------------------------ */
/* These are called from Chasm scripts via extern declarations in godot.chasm.
 * g_current_inst is set around every script dispatch so shims know the owner. */

/* Vector2 in Godot 4 is two 32-bit floats (8 bytes total). */
typedef struct { float x; float y; } GodotVector2;

/* ---- Position ----------------------------------------------------------- */

double gdot_get_pos_x(void) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_node2d_get_global_pos) return 0.0;
    GodotVector2 pos = {0, 0};
    gde_ptrcall(bind_node2d_get_global_pos, inst->owner, NULL, &pos);
    return pos.x;
}

double gdot_get_pos_y(void) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_node2d_get_global_pos) return 0.0;
    GodotVector2 pos = {0, 0};
    gde_ptrcall(bind_node2d_get_global_pos, inst->owner, NULL, &pos);
    return pos.y;
}

void gdot_set_position(double x, double y) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_node2d_set_global_pos) return;
    GodotVector2 pos = {(float)x, (float)y};
    const void *args[] = {&pos};
    gde_ptrcall(bind_node2d_set_global_pos, inst->owner, args, NULL);
}

/* ---- Physics ------------------------------------------------------------ */

void gdot_move_and_slide(void) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_charbody2d_move_and_slide) return;
    GDExtensionBool result;
    gde_ptrcall(bind_charbody2d_move_and_slide, inst->owner, NULL, &result);
}

void gdot_set_velocity(double vx, double vy) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_charbody2d_set_velocity) return;
    GodotVector2 v = {(float)vx, (float)vy};
    const void *args[] = {&v};
    gde_ptrcall(bind_charbody2d_set_velocity, inst->owner, args, NULL);
}

double gdot_get_vel_x(void) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_charbody2d_get_velocity) return 0.0;
    GodotVector2 v = {0, 0};
    gde_ptrcall(bind_charbody2d_get_velocity, inst->owner, NULL, &v);
    return v.x;
}

double gdot_get_vel_y(void) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_charbody2d_get_velocity) return 0.0;
    GodotVector2 v = {0, 0};
    gde_ptrcall(bind_charbody2d_get_velocity, inst->owner, NULL, &v);
    return v.y;
}

/* ---- Signals ------------------------------------------------------------ */

void gdot_emit_signal(const char *signal_name) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_object_emit_signal || !signal_name) return;
    uint8_t sn_sig[8] = {0};
    gde_sn_new((GDExtensionUninitializedStringNamePtr)sn_sig, signal_name,
               GDEXTENSION_FALSE);
    const void *args[] = {sn_sig};
    gde_ptrcall(bind_object_emit_signal, inst->owner, args, NULL);
}

/* ---- Scene tree --------------------------------------------------------- */

int64_t gdot_get_node(const char *path) {
    ChasmInstance *inst = g_current_inst;
    if (!inst || !bind_node_get_node || !path) return 0;
    uint8_t np[8] = {0};
    gde_str_new((GDExtensionUninitializedStringPtr)np, path);
    const void *args[] = {np};
    GDExtensionObjectPtr result = NULL;
    gde_ptrcall(bind_node_get_node, inst->owner, args, &result);
    return (int64_t)(uintptr_t)result;
}

/* ---- Audio -------------------------------------------------------------- */

void gdot_play_audio(const char *path) {
    /* Simple approach: spawn AudioStreamPlayer via @tool or scene path.
     * A full binding requires resolving the audio server. For v1, log intent. */
    (void)path;
    fprintf(stderr, "[chasm_gde] gdot_play_audio: %s (stub — wire AudioStreamPlayer)\n",
            path ? path : "(null)");
}

/* ---- Input -------------------------------------------------------------- */

/* Input is a singleton in Godot 4. We need the Input singleton object pointer.
 * gdot_input_singleton is resolved once after the scene initializes. */
static GDExtensionObjectPtr gdot_input_singleton;

static GDExtensionObjectPtr get_input_singleton(void) {
    if (gdot_input_singleton) return gdot_input_singleton;
    /* Input singleton is always named "Input" in Godot 4. */
    static void *bind_engine_get_singleton;
    static uint8_t SN_ENGINE[8];
    static uint8_t SN_GET_SINGLETON[8];
    static uint8_t SN_INPUT_NAME[8];
    static int resolved;
    if (!resolved) {
        resolved = 1;
        gde_sn_new((GDExtensionUninitializedStringNamePtr)SN_ENGINE,
                   "Engine", GDEXTENSION_TRUE);
        gde_sn_new((GDExtensionUninitializedStringNamePtr)SN_GET_SINGLETON,
                   "get_singleton", GDEXTENSION_TRUE);
        gde_sn_new((GDExtensionUninitializedStringNamePtr)SN_INPUT_NAME,
                   "Input", GDEXTENSION_FALSE);
        bind_engine_get_singleton = gde_get_method_bind(
            (GDExtensionConstStringNamePtr)SN_ENGINE,
            (GDExtensionConstStringNamePtr)SN_GET_SINGLETON,
            2336340620LL);
    }
    if (!bind_engine_get_singleton) return NULL;
    /* Engine.get_singleton("Input") returns the Input node. */
    uint8_t sn_input[8] = {0};
    gde_sn_new((GDExtensionUninitializedStringNamePtr)sn_input, "Input",
               GDEXTENSION_FALSE);
    const void *args[] = {sn_input};
    GDExtensionObjectPtr singleton = NULL;
    gde_ptrcall(bind_engine_get_singleton, NULL, args, &singleton);
    gdot_input_singleton = singleton;
    return singleton;
}

bool gdot_is_action_pressed(const char *action) {
    GDExtensionObjectPtr input = get_input_singleton();
    if (!input || !bind_input_is_action_pressed || !action) return false;
    uint8_t sn[8] = {0};
    gde_sn_new((GDExtensionUninitializedStringNamePtr)sn, action, GDEXTENSION_FALSE);
    GDExtensionBool exact = GDEXTENSION_FALSE;
    const void *args[] = {sn, &exact};
    GDExtensionBool result = GDEXTENSION_FALSE;
    gde_ptrcall(bind_input_is_action_pressed, input, args, &result);
    return result != 0;
}

bool gdot_is_action_just_pressed(const char *action) {
    GDExtensionObjectPtr input = get_input_singleton();
    if (!input || !bind_input_is_action_just_pressed || !action) return false;
    uint8_t sn[8] = {0};
    gde_sn_new((GDExtensionUninitializedStringNamePtr)sn, action, GDEXTENSION_FALSE);
    GDExtensionBool exact = GDEXTENSION_FALSE;
    const void *args[] = {sn, &exact};
    GDExtensionBool result = GDEXTENSION_FALSE;
    gde_ptrcall(bind_input_is_action_just_pressed, input, args, &result);
    return result != 0;
}

bool gdot_is_action_just_released(const char *action) {
    GDExtensionObjectPtr input = get_input_singleton();
    if (!input || !bind_input_is_action_just_released || !action) return false;
    uint8_t sn[8] = {0};
    gde_sn_new((GDExtensionUninitializedStringNamePtr)sn, action, GDEXTENSION_FALSE);
    GDExtensionBool exact = GDEXTENSION_FALSE;
    const void *args[] = {sn, &exact};
    GDExtensionBool result = GDEXTENSION_FALSE;
    gde_ptrcall(bind_input_is_action_just_released, input, args, &result);
    return result != 0;
}

double gdot_get_axis(const char *neg_action, const char *pos_action) {
    GDExtensionObjectPtr input = get_input_singleton();
    if (!input || !bind_input_get_axis || !neg_action || !pos_action) return 0.0;
    uint8_t sn_neg[8] = {0}, sn_pos[8] = {0};
    gde_sn_new((GDExtensionUninitializedStringNamePtr)sn_neg, neg_action, GDEXTENSION_FALSE);
    gde_sn_new((GDExtensionUninitializedStringNamePtr)sn_pos, pos_action, GDEXTENSION_FALSE);
    const void *args[] = {sn_neg, sn_pos};
    float result = 0.0f;
    gde_ptrcall(bind_input_get_axis, input, args, &result);
    return (double)result;
}

/* ---- Logging ------------------------------------------------------------ */

void gdot_print(const char *msg) {
    if (msg) fprintf(stdout, "[Chasm] %s\n", msg);
}

void gdot_print_err(const char *msg) {
    if (msg) fprintf(stderr, "[Chasm:ERR] %s\n", msg);
}
