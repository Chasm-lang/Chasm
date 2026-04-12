/*
 * chasm_standalone.c — minimal main() harness for standalone Chasm binaries.
 *
 * Compile together with generated compiler output:
 *   cc -O2 -o chasm compiler_out.c chasm_standalone.c -I runtime/
 */
#include <stdlib.h>
#include "chasm_rt.h"

/* chasm_module_init is only emitted for scripts that have @attr declarations.
 * Declare it as a weak symbol so the harness links cleanly when it is absent. */
__attribute__((weak)) void chasm_module_init(ChasmCtx *ctx) { (void)ctx; }
void chasm_main(ChasmCtx *ctx);

int main(void) {
    size_t frame_cap  = (size_t)4 * 1024 * 1024 * 1024; /* 4 GB */
    size_t script_cap = 8 * 1024 * 1024;
    size_t persist_cap= 8 * 1024 * 1024;
    uint8_t *frame_buf   = (uint8_t *)malloc(frame_cap);
    uint8_t *script_buf  = (uint8_t *)malloc(script_cap);
    uint8_t *persist_buf = (uint8_t *)malloc(persist_cap);
    if (!frame_buf || !script_buf || !persist_buf) {
        fprintf(stderr, "chasm: failed to allocate arenas\n");
        return 1;
    }
    ChasmCtx ctx = {
        .frame      = { frame_buf,   0, frame_cap   },
        .script     = { script_buf,  0, script_cap  },
        .persistent = { persist_buf, 0, persist_cap },
    };
    chasm_ctx_init_gc(&ctx);
    chasm_module_init(&ctx);
    chasm_main(&ctx);
    return 0;
}
