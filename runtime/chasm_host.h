#pragma once
/*
 * chasm_host.h — Stable embedding API for hosting Chasm scripts in any C engine.
 *
 * Include this header (instead of chasm_rt.h) to embed a Chasm script in your
 * engine. It provides the full runtime plus the lifecycle typedefs, arena setup
 * helpers, and the native function naming contract.
 *
 * Two embedding modes:
 *
 *   Dynamic (hot-reload, recommended for development):
 *     #include "path/to/runtime/chasm_host.h"
 *     #include "path/to/engine/loader.h"   // handles dlopen/dlsym/dlclose
 *     // Then use ChasmLoader: chasm_loader_open, chasm_loader_reload, etc.
 *
 *   Static (link the compiled .c directly, simpler for shipping):
 *     #define CHASM_STATIC_SCRIPT
 *     #include "path/to/runtime/chasm_host.h"
 *     CHASM_LIFECYCLE_DECLS;               // forward-declares the five symbols
 *     // Call directly: chasm_module_init(&ctx); chasm_on_tick(&ctx, dt); etc.
 *
 * Minimal host setup (either mode):
 *
 *     CHASM_DEFAULT_ARENAS(ctx);           // declare static arenas + ChasmCtx
 *     chasm_module_init(&ctx);             // run @attr initializers
 *     // ... main loop:
 *     chasm_on_tick(&ctx, dt);
 *     chasm_on_draw(&ctx);
 *     chasm_clear_frame(&ctx);             // reclaim frame allocations each tick
 */
#include "chasm_rt.h"

/* ---- Lifecycle function typedefs ---------------------------------------- */
/*
 * These match the signatures the Chasm compiler emits for the five lifecycle
 * hooks. Required: module_init, on_tick, on_draw. Optional: on_init,
 * on_unload, reload_migrate (the dynamic loader substitutes no-ops if absent).
 */
typedef void (*ChasmModuleInitFn)   (ChasmCtx *);
typedef void (*ChasmOnTickFn)       (ChasmCtx *, double /* dt */);
typedef void (*ChasmOnDrawFn)       (ChasmCtx *);
typedef void (*ChasmOnInitFn)       (ChasmCtx *);
typedef void (*ChasmOnUnloadFn)     (ChasmCtx *);
typedef void (*ChasmReloadMigrateFn)(ChasmCtx *);

/* ---- Arena setup helpers ------------------------------------------------- */
/*
 * CHASM_DECLARE_ARENAS — declare three static byte arrays at given sizes.
 * CHASM_CTX_INIT       — zero-init a ChasmCtx from those arrays.
 * CHASM_DEFAULT_ARENAS — convenience: declare + init with recommended sizes.
 *
 * Recommended sizes (also used by the Raylib engine):
 *   frame      1 MB  — cleared every tick (temporaries, string allocations)
 *   script     4 MB  — reset on hot-reload (persistent game state)
 *   persistent 16 MB — never cleared (high scores, save data)
 *
 * You can tune the sizes for your game's memory budget. Larger frame arenas
 * allow more string/array operations per tick before wrapping.
 *
 * Usage:
 *   int main(void) {
 *       CHASM_DEFAULT_ARENAS(ctx);
 *       // ctx is now a valid ChasmCtx; pass &ctx everywhere.
 *   }
 */
#define CHASM_DECLARE_ARENAS(frame_sz, script_sz, persist_sz)          \
    static uint8_t _chasm_frame_buf  [(frame_sz)];                     \
    static uint8_t _chasm_script_buf [(script_sz)];                    \
    static uint8_t _chasm_persist_buf[(persist_sz)]

#define CHASM_CTX_INIT(ctx)                                            \
    ChasmCtx ctx = {                                                   \
        .frame      = { _chasm_frame_buf,   0, sizeof(_chasm_frame_buf)   }, \
        .script     = { _chasm_script_buf,  0, sizeof(_chasm_script_buf)  }, \
        .persistent = { _chasm_persist_buf, 0, sizeof(_chasm_persist_buf) }, \
    }

#define CHASM_DEFAULT_ARENAS(ctx)                                      \
    CHASM_DECLARE_ARENAS(1*1024*1024, 4*1024*1024, 16*1024*1024);     \
    CHASM_CTX_INIT(ctx)

/* ---- Native function naming contract ------------------------------------- */
/*
 * Every C function exposed to a Chasm script must follow this naming scheme
 * so the Chasm codegen can locate it — no runtime registration is required:
 *
 *   chasm_<name>(ChasmCtx *ctx, <arg types...>)
 *
 * Example — expose "add_score" to scripts:
 *
 *   static int64_t g_score = 0;
 *
 *   void chasm_add_score(ChasmCtx *ctx, int64_t delta) {
 *       (void)ctx;
 *       g_score += delta;
 *   }
 *
 * In Chasm source, declare it once:
 *
 *   extern fn add_score(delta :: int) -> void
 *
 * The compiler emits `chasm_add_score(ctx, delta)` at every call site.
 * No registration step — the naming convention IS the registry.
 *
 * For engine-specific bindings (Raylib, SDL, etc.), use a shim header that
 * maps chasm_<name> to the engine's native function. See:
 *   engine/raylib/chasm_rl_shim.h   — Raylib binding shim (template)
 */

/* ---- Static-link convenience --------------------------------------------- */
/*
 * Define CHASM_STATIC_SCRIPT before including this header when linking the
 * compiled Chasm .c directly (no dlopen). Then place CHASM_LIFECYCLE_DECLS
 * anywhere that needs to call the lifecycle functions.
 */
#ifdef CHASM_STATIC_SCRIPT
#  define CHASM_LIFECYCLE_DECLS                               \
    extern void chasm_module_init   (ChasmCtx *);            \
    extern void chasm_on_tick       (ChasmCtx *, double);    \
    extern void chasm_on_draw       (ChasmCtx *);            \
    extern void chasm_on_init       (ChasmCtx *);            \
    extern void chasm_on_unload     (ChasmCtx *);            \
    extern void chasm_reload_migrate(ChasmCtx *)
#endif
