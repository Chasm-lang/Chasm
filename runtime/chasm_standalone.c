/*
 * chasm_standalone.c — minimal main() harness for standalone Chasm binaries.
 *
 * Compile together with generated compiler output:
 *   cc -O2 -o chasm compiler_out.c chasm_standalone.c -I runtime/
 */
#include "chasm_rt.h"

void chasm_main(ChasmCtx *ctx);

int main(void) {
    static uint8_t frame_buf  [8 * 1024 * 1024];
    static uint8_t script_buf [8 * 1024 * 1024];
    static uint8_t persist_buf[8 * 1024 * 1024];
    ChasmCtx ctx = {
        .frame      = { frame_buf,   0, sizeof(frame_buf)   },
        .script     = { script_buf,  0, sizeof(script_buf)  },
        .persistent = { persist_buf, 0, sizeof(persist_buf) },
    };
    chasm_main(&ctx);
    return 0;
}
