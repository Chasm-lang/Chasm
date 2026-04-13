#include "../../runtime/chasm_rt.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    ChasmCtx ctx = {0};

    /* Basic set/get */
    ChasmMap m = chasm_map_new(&ctx, 8);
    chasm_map_set_i(&ctx, &m, "score", 100);
    chasm_map_set_s(&ctx, &m, "name", "alice");
    assert(chasm_map_get_i(&ctx, &m, "score") == 100);
    assert(strcmp(chasm_map_get_s(&ctx, &m, "name"), "alice") == 0);

    /* has / len */
    assert(chasm_map_has(&ctx, &m, "score") == 1);
    assert(chasm_map_has(&ctx, &m, "missing") == 0);
    assert(chasm_map_len(&ctx, &m) == 2);

    /* delete */
    chasm_map_del(&ctx, &m, "score");
    assert(chasm_map_has(&ctx, &m, "score") == 0);
    assert(chasm_map_len(&ctx, &m) == 1);

    /* update existing key does not bump len */
    chasm_map_set_i(&ctx, &m, "x", 1);
    chasm_map_set_i(&ctx, &m, "x", 2);
    assert(chasm_map_get_i(&ctx, &m, "x") == 2);
    assert(chasm_map_len(&ctx, &m) == 2);

    /* float and bool variants */
    chasm_map_set_f(&ctx, &m, "pi", 3.14);
    chasm_map_set_b(&ctx, &m, "ok", 1);
    assert(chasm_map_get_f(&ctx, &m, "pi") > 3.0);
    assert(chasm_map_get_b(&ctx, &m, "ok") == 1);

    /* safe defaults for missing keys */
    assert(chasm_map_get_i(&ctx, &m, "none") == 0);
    assert(strcmp(chasm_map_get_s(&ctx, &m, "none"), "") == 0);

    printf("map runtime OK\n");
    free(m.keys); free(m.vals);
    return 0;
}
