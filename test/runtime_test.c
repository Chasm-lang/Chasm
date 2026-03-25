/*
 * runtime_test.c — Comprehensive tests for chasm_rt.h
 *
 * Build & run (standalone runtime):
 *   clang -std=c11 -g -fsanitize=address,undefined \
 *     -o /tmp/runtime_test test/runtime_test.c -I runtime/ -lm && /tmp/runtime_test
 *
 * Build & run (engine runtime):
 *   clang -std=c11 -g -fsanitize=address,undefined \
 *     -o /tmp/runtime_test_engine test/runtime_test.c -I engine/raylib/ -lm && /tmp/runtime_test_engine
 */
#include "chasm_rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ---- minimal test harness ---------------------------------------- */

static int _pass = 0, _fail = 0;
#define CHECK(cond, msg) do { \
    if (cond) { _pass++; } \
    else { fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); _fail++; } \
} while(0)
#define CHECK_EQ_I(a,b,msg)  CHECK((a)==(b),  msg)
#define CHECK_EQ_S(a,b,msg)  CHECK(strcmp((a),(b))==0, msg)
#define CHECK_NEAR(a,b,msg)  CHECK(fabs((a)-(b))<1e-9, msg)

/* Build a ChasmCtx backed by stack buffers. */
static ChasmCtx make_ctx(void) {
    static uint8_t fb[1*1024*1024];
    static uint8_t sb[4*1024*1024];
    static uint8_t pb[2*1024*1024];
    memset(fb, 0, sizeof(fb));
    memset(sb, 0, sizeof(sb));
    memset(pb, 0, sizeof(pb));
    ChasmCtx ctx = {
        .frame      = { fb, 0, sizeof(fb) },
        .script     = { sb, 0, sizeof(sb) },
        .persistent = { pb, 0, sizeof(pb) },
    };
#ifdef CHASM_FRAME_HEAP_CAP
    chasm_ctx_init_gc(&ctx);
#endif
    return ctx;
}

/* ================================================================== */
/* 1. Arena allocator                                                  */
/* ================================================================== */
static void test_arena(void) {
    ChasmCtx ctx = make_ctx();

    /* basic alloc */
    void *p1 = chasm_alloc(&ctx.frame, 16, 8);
    CHECK(p1 != NULL, "arena: alloc 16 bytes");

    /* alignment: result must be 8-byte aligned */
    CHECK(((uintptr_t)p1 & 7) == 0, "arena: 8-byte alignment");

    /* alloc advances pointer */
    void *p2 = chasm_alloc(&ctx.frame, 8, 8);
    CHECK(p2 != NULL, "arena: second alloc");
    CHECK((uint8_t*)p2 >= (uint8_t*)p1 + 16, "arena: no overlap");

    /* chasm_clear_frame resets used counter */
    size_t used_before = ctx.frame.used;
    chasm_clear_frame(&ctx);
    CHECK(ctx.frame.used == 0, "arena: frame cleared");
    (void)used_before;

    /* re-alloc after clear returns same base */
    void *p3 = chasm_alloc(&ctx.frame, 16, 8);
    CHECK(p3 == p1, "arena: reuse after clear");

    /* OOM returns NULL */
    ctx.frame.used = ctx.frame.cap; /* fill to capacity */
    void *poom = chasm_alloc(&ctx.frame, 1, 1);
    CHECK(poom == NULL, "arena: OOM returns NULL");
    ctx.frame.used = 0;
}

/* ================================================================== */
/* 2. Frame GC — arrays freed on chasm_clear_frame                    */
/* ================================================================== */
static void test_frame_gc(void) {
    ChasmCtx ctx = make_ctx();

    /* Create several arrays; they should be tracked */
    ChasmArray a1 = chasm_array_new(&ctx, 4);
    ChasmArray a2 = chasm_array_new(&ctx, 8);
    ChasmArray a3 = chasm_array_new(&ctx, 16);

    chasm_array_push(&ctx, &a1, 10);
    chasm_array_push(&ctx, &a2, 20);
    chasm_array_push(&ctx, &a2, 21);

    CHECK_EQ_I(chasm_array_get(&ctx, &a1, 0), 10, "gc: array values before clear");
    CHECK_EQ_I(chasm_array_len(&ctx, &a2), 2, "gc: array len before clear");
    (void)a3;

#ifdef CHASM_FRAME_HEAP_CAP
    /* Frame-heap GC is present (standalone runtime) */
    int n_before = chasm_fh_count(&ctx);
    CHECK(n_before >= 3, "gc: 3 arrays registered in frame heap");

    chasm_clear_frame(&ctx); /* should free a1, a2, a3 without crashing */
    CHECK_EQ_I(chasm_fh_count(&ctx), 0, "gc: frame heap count reset to 0");
    CHECK_EQ_I((int)ctx.frame.used, 0, "gc: frame arena reset");

    /* Reuse: create a new array after clear — must not crash */
    ChasmArray a4 = chasm_array_new(&ctx, 4);
    chasm_array_push(&ctx, &a4, 42);
    CHECK_EQ_I(chasm_array_get(&ctx, &a4, 0), 42, "gc: new array after clear");
    chasm_clear_frame(&ctx);
#else
    /* Engine runtime: arrays live in frame arena, clear resets arena */
    chasm_clear_frame(&ctx);
    CHECK_EQ_I((int)ctx.frame.used, 0, "gc: engine frame arena reset");
#endif
}

/* ================================================================== */
/* 3. String operations                                               */
/* ================================================================== */
static void test_strings(void) {
    ChasmCtx ctx = make_ctx();

    CHECK_EQ_S(chasm_str_concat(&ctx, "hello", " world"), "hello world", "str_concat basic");
    CHECK_EQ_S(chasm_str_concat(&ctx, "", "abc"), "abc", "str_concat empty left");
    CHECK_EQ_S(chasm_str_concat(&ctx, "abc", ""), "abc", "str_concat empty right");
    CHECK_EQ_I(chasm_str_len(&ctx, "hello"), 5, "str_len");
    CHECK_EQ_I(chasm_str_len(&ctx, ""), 0, "str_len empty");
    CHECK_EQ_I(chasm_str_len(&ctx, NULL), 0, "str_len NULL");

    CHECK_EQ_S(chasm_str_slice(&ctx, "hello", 1, 4), "ell", "str_slice");
    CHECK_EQ_S(chasm_str_slice(&ctx, "hello", 0, 5), "hello", "str_slice full");
    CHECK_EQ_S(chasm_str_slice(&ctx, "hello", 2, 2), "", "str_slice empty range");

    CHECK_EQ_S(chasm_str_upper(&ctx, "hello"), "HELLO", "str_upper");
    CHECK_EQ_S(chasm_str_lower(&ctx, "HELLO"), "hello", "str_lower");
    CHECK_EQ_S(chasm_str_trim(&ctx, "  hi  "), "hi", "str_trim");

    CHECK(chasm_str_contains(&ctx, "hello world", "world"), "str_contains true");
    CHECK(!chasm_str_contains(&ctx, "hello", "xyz"), "str_contains false");
    CHECK(chasm_str_starts_with(&ctx, "hello", "hel"), "str_starts_with");
    CHECK(chasm_str_ends_with(&ctx, "hello", "llo"), "str_ends_with");
    CHECK(chasm_str_eq(&ctx, "abc", "abc"), "str_eq true");
    CHECK(!chasm_str_eq(&ctx, "abc", "def"), "str_eq false");

    CHECK_EQ_S(chasm_int_to_str(&ctx, 42), "42", "int_to_str");
    CHECK_EQ_S(chasm_int_to_str(&ctx, -7), "-7", "int_to_str negative");
    CHECK_EQ_S(chasm_int_to_str(&ctx, 0), "0", "int_to_str zero");
    CHECK_EQ_S(chasm_bool_to_str(&ctx, 1), "true", "bool_to_str true");
    CHECK_EQ_S(chasm_bool_to_str(&ctx, 0), "false", "bool_to_str false");

    CHECK_EQ_I(chasm_str_char_at(&ctx, "abc", 0), 'a', "str_char_at 0");
    CHECK_EQ_I(chasm_str_char_at(&ctx, "abc", 2), 'c', "str_char_at 2");
    CHECK_EQ_I(chasm_str_char_at(&ctx, "abc", 5), 0, "str_char_at oob");

    const char *sc = chasm_str_from_char(&ctx, 'X');
    CHECK_EQ_S(sc, "X", "str_from_char");

    CHECK_EQ_S(chasm_str_repeat(&ctx, "ab", 3), "ababab", "str_repeat");
    CHECK_EQ_S(chasm_str_repeat(&ctx, "x", 0), "", "str_repeat 0");
}

/* ================================================================== */
/* 4. str_to_script / str_to_persistent — string GC promotion        */
/* ================================================================== */
static void test_str_promotion(void) {
    ChasmCtx ctx = make_ctx();

    /* Build a string on the frame arena */
    const char *s = chasm_str_concat(&ctx, "foo", "bar");
    CHECK_EQ_S(s, "foobar", "str promotion: concat ok");

    /* Copy to script arena */
    const char *ss = chasm_str_to_script(&ctx, s);
    CHECK_EQ_S(ss, "foobar", "str promotion: script copy ok");

    /* After frame clear the script copy should still be valid */
    chasm_clear_frame(&ctx);
    CHECK_EQ_S(ss, "foobar", "str promotion: script string survives frame clear");

    /* Copy to persistent arena */
    const char *sp = chasm_str_to_persistent(&ctx, "hello");
    chasm_clear_frame(&ctx);
    CHECK_EQ_S(sp, "hello", "str promotion: persistent string survives frame clear");

    /* Verify script arena is NOT cleared by chasm_clear_frame */
    size_t script_used = ctx.script.used;
    chasm_clear_frame(&ctx);
    CHECK(ctx.script.used == script_used, "str promotion: script arena intact after frame clear");
}

/* ================================================================== */
/* 5. Array operations                                                 */
/* ================================================================== */
static void test_arrays(void) {
    ChasmCtx ctx = make_ctx();

    ChasmArray a = chasm_array_new(&ctx, 4);
    CHECK_EQ_I(chasm_array_len(&ctx, &a), 0, "array: initial len 0");

    chasm_array_push(&ctx, &a, 10);
    chasm_array_push(&ctx, &a, 20);
    chasm_array_push(&ctx, &a, 30);
    CHECK_EQ_I(chasm_array_len(&ctx, &a), 3, "array: len after 3 pushes");
    CHECK_EQ_I(chasm_array_get(&ctx, &a, 0), 10, "array: get[0]");
    CHECK_EQ_I(chasm_array_get(&ctx, &a, 2), 30, "array: get[2]");

    chasm_array_set(&ctx, &a, 1, 99);
    CHECK_EQ_I(chasm_array_get(&ctx, &a, 1), 99, "array: set then get");

    int64_t popped = chasm_array_pop(&ctx, &a);
    CHECK_EQ_I(popped, 30, "array: pop value");
    CHECK_EQ_I(chasm_array_len(&ctx, &a), 2, "array: len after pop");

    /* out-of-bounds get returns 0 */
    CHECK_EQ_I(chasm_array_get(&ctx, &a, 100), 0, "array: oob get returns 0");
    /* pop on empty returns 0 */
    chasm_array_clear(&ctx, &a);
    CHECK_EQ_I(chasm_array_pop(&ctx, &a), 0, "array: pop empty returns 0");

#ifdef CHASM_FRAME_HEAP_CAP
    /* Growth beyond initial cap (standalone runtime) */
    ChasmArray b = chasm_array_new(&ctx, 2);
    for (int i = 0; i < 10; i++) chasm_array_push(&ctx, &b, (int64_t)i);
    CHECK_EQ_I(chasm_array_len(&ctx, &b), 10, "array: growth beyond initial cap");
    CHECK_EQ_I(chasm_array_get(&ctx, &b, 9), 9, "array: correct value after growth");
#endif
    chasm_clear_frame(&ctx);
}

/* ================================================================== */
/* 6. Range                                                            */
/* ================================================================== */
static void test_range(void) {
    ChasmCtx ctx = make_ctx();

    ChasmArray r = chasm_range(&ctx, 0, 5);
    CHECK_EQ_I(chasm_array_len(&ctx, &r), 5, "range: len");
    CHECK_EQ_I(chasm_array_get(&ctx, &r, 0), 0, "range: get[0]");
    CHECK_EQ_I(chasm_array_get(&ctx, &r, 4), 4, "range: get[4]");

    ChasmArray r2 = chasm_range(&ctx, 3, 3);
    CHECK_EQ_I(chasm_array_len(&ctx, &r2), 0, "range: empty range len");

    ChasmArray r3 = chasm_range(&ctx, 5, 3);
    CHECK_EQ_I(chasm_array_len(&ctx, &r3), 0, "range: inverted range len");

    chasm_clear_frame(&ctx);
}

/* ================================================================== */
/* 7. Math functions                                                   */
/* ================================================================== */
static void test_math(void) {
    ChasmCtx ctx = make_ctx();

    CHECK_NEAR(chasm_floor(&ctx, 3.7),  3.0, "floor");
    CHECK_NEAR(chasm_ceil (&ctx, 3.2),  4.0, "ceil");
    CHECK_NEAR(chasm_round(&ctx, 3.5),  4.0, "round");
    CHECK_NEAR(chasm_abs  (&ctx, -5.0), 5.0, "abs");
    CHECK_NEAR(chasm_sqrt (&ctx, 4.0),  2.0, "sqrt");
    CHECK_NEAR(chasm_pow  (&ctx, 2.0, 8.0), 256.0, "pow");
    CHECK_NEAR(chasm_lerp (&ctx, 0.0, 10.0, 0.5), 5.0, "lerp");
    CHECK_NEAR(chasm_clamp(&ctx, 150.0, 0.0, 100.0), 100.0, "clamp high");
    CHECK_NEAR(chasm_clamp(&ctx, -10.0, 0.0, 100.0), 0.0,   "clamp low");
    CHECK_NEAR(chasm_clamp(&ctx, 50.0,  0.0, 100.0), 50.0,  "clamp mid");
    CHECK_NEAR(chasm_min  (&ctx, 3.0, 7.0), 3.0, "min");
    CHECK_NEAR(chasm_max  (&ctx, 3.0, 7.0), 7.0, "max");
    CHECK_NEAR(chasm_sign (&ctx, -5.0), -1.0, "sign negative");
    CHECK_NEAR(chasm_sign (&ctx,  5.0),  1.0, "sign positive");
    CHECK_NEAR(chasm_sign (&ctx,  0.0),  0.0, "sign zero");
    CHECK_NEAR(chasm_fract(&ctx, 3.75), 0.75, "fract");
    CHECK_NEAR(chasm_deg_to_rad(&ctx, 180.0), 3.14159265358979323846, "deg_to_rad");
    CHECK_NEAR(chasm_rad_to_deg(&ctx, 3.14159265358979323846), 180.0, "rad_to_deg");
    CHECK_NEAR(chasm_snap(&ctx, 7.3, 2.0), 8.0, "snap");
    CHECK_NEAR(chasm_wrap(&ctx, 11.0, 0.0, 10.0), 1.0, "wrap");
    CHECK_NEAR(chasm_move_toward(&ctx, 0.0, 10.0, 3.0), 3.0, "move_toward");
    CHECK_NEAR(chasm_move_toward(&ctx, 9.0, 10.0, 3.0), 10.0, "move_toward clamp");
    CHECK_NEAR(chasm_smooth_step(&ctx, 0.0, 1.0, 0.5), 0.5, "smooth_step mid");
    CHECK_NEAR(chasm_smooth_step(&ctx, 0.0, 1.0, 0.0), 0.0, "smooth_step lo");
    CHECK_NEAR(chasm_smooth_step(&ctx, 0.0, 1.0, 1.0), 1.0, "smooth_step hi");
    CHECK_NEAR(chasm_ease_in (&ctx, 0.5), 0.25, "ease_in");
    CHECK_NEAR(chasm_ease_out(&ctx, 0.5), 0.75, "ease_out");
}

/* ================================================================== */
/* 8. Type conversion                                                  */
/* ================================================================== */
static void test_conversion(void) {
    ChasmCtx ctx = make_ctx();

    CHECK_EQ_I(chasm_to_int(&ctx, 3.9), 3, "to_int truncates");
    CHECK_NEAR(chasm_to_float(&ctx, 7), 7.0, "to_float");
    CHECK(chasm_to_bool(&ctx, 1),  "to_bool nonzero");
    CHECK(!chasm_to_bool(&ctx, 0), "to_bool zero");
}

/* ================================================================== */
/* 9. Color helpers                                                    */
/* ================================================================== */
static void test_color(void) {
    ChasmCtx ctx = make_ctx();

    int64_t c = chasm_rgba(&ctx, 255, 128, 64, 32);
    CHECK_EQ_I(chasm_color_r(&ctx, c), 255, "color_r");
    CHECK_EQ_I(chasm_color_g(&ctx, c), 128, "color_g");
    CHECK_EQ_I(chasm_color_b(&ctx, c), 64,  "color_b");
    CHECK_EQ_I(chasm_color_a(&ctx, c), 32,  "color_a");

    int64_t white  = chasm_rgb(&ctx, 255, 255, 255);
    int64_t black  = chasm_rgb(&ctx, 0, 0, 0);
    int64_t mid    = chasm_color_lerp(&ctx, white, black, 0.5);
    CHECK(chasm_color_r(&ctx, mid) >= 127 && chasm_color_r(&ctx, mid) <= 128, "color_lerp r");
}

/* ================================================================== */
/* 10. Bitwise                                                         */
/* ================================================================== */
static void test_bitwise(void) {
    ChasmCtx ctx = make_ctx();

    CHECK_EQ_I(chasm_bit_and(&ctx, 0xF0, 0x0F), 0,    "bit_and");
    CHECK_EQ_I(chasm_bit_and(&ctx, 0xFF, 0x0F), 0x0F, "bit_and 2");
    CHECK_EQ_I(chasm_bit_or (&ctx, 0xF0, 0x0F), 0xFF, "bit_or");
    CHECK_EQ_I(chasm_bit_xor(&ctx, 0xFF, 0x0F), 0xF0, "bit_xor");
    CHECK_EQ_I(chasm_bit_not(&ctx, 0) & 0xFF,   0xFF, "bit_not");
    CHECK_EQ_I(chasm_bit_shl(&ctx, 1, 4),  16, "bit_shl");
    CHECK_EQ_I(chasm_bit_shr(&ctx, 16, 2),  4, "bit_shr");
}

/* ================================================================== */
/* 11. Vec2                                                            */
/* ================================================================== */
static void test_vec2(void) {
    ChasmCtx ctx = make_ctx();

    CHECK_NEAR(chasm_vec2_len(&ctx, 3.0, 4.0), 5.0, "vec2_len");
    CHECK_NEAR(chasm_vec2_dot(&ctx, 1.0, 0.0, 0.0, 1.0), 0.0, "vec2_dot perp");
    CHECK_NEAR(chasm_vec2_dot(&ctx, 1.0, 0.0, 1.0, 0.0), 1.0, "vec2_dot parallel");
    CHECK_NEAR(chasm_vec2_dist(&ctx, 0.0, 0.0, 3.0, 4.0), 5.0, "vec2_dist");

    double nx = chasm_vec2_norm_x(&ctx, 3.0, 4.0);
    double ny = chasm_vec2_norm_y(&ctx, 3.0, 4.0);
    CHECK_NEAR(chasm_vec2_len(&ctx, nx, ny), 1.0, "vec2_norm is unit");
}

/* ================================================================== */
/* 12. Arena stress — ensure no corruption after many allocs          */
/* ================================================================== */
static void test_arena_stress(void) {
    ChasmCtx ctx = make_ctx();

    /* 1000 frame cycles: alloc strings and arrays each frame */
    for (int cycle = 0; cycle < 1000; cycle++) {
        const char *s = chasm_str_concat(&ctx, "hello", " world");
        const char *n = chasm_int_to_str(&ctx, (int64_t)cycle);
        ChasmArray  a = chasm_array_new(&ctx, 8);
        chasm_array_push(&ctx, &a, (int64_t)cycle);
        (void)s; (void)n;
        chasm_clear_frame(&ctx);
    }
    CHECK(1, "arena_stress: 1000 cycles without crash");

    /* After 1000 clears the frame arena should still be empty */
    CHECK_EQ_I((int)ctx.frame.used, 0, "arena_stress: frame clean after stress");
}

/* ================================================================== */
/* 13. Rand (basic: just verify range)                                 */
/* ================================================================== */
static void test_rand(void) {
    ChasmCtx ctx = make_ctx();
    int ok = 1;
    for (int i = 0; i < 1000; i++) {
        double r = chasm_rand(&ctx);
        if (r < 0.0 || r >= 1.0) { ok = 0; break; }
    }
    CHECK(ok, "rand: 1000 values in [0,1)");

    int ok_int = 1;
    for (int i = 0; i < 1000; i++) {
        int64_t n = chasm_rand_int(&ctx, 1, 7);
        if (n < 1 || n >= 7) { ok_int = 0; break; }
    }
    CHECK(ok_int, "rand_int: 1000 values in [1,7)");
}

/* ================================================================== */
/* main                                                                */
/* ================================================================== */
int main(void) {
    printf("=== Chasm runtime tests ===\n");

    test_arena();
    test_frame_gc();
    test_strings();
    test_str_promotion();
    test_arrays();
    test_range();
    test_math();
    test_conversion();
    test_color();
    test_bitwise();
    test_vec2();
    test_arena_stress();
    test_rand();

    printf("\n%d passed, %d failed\n", _pass, _fail);
    return _fail > 0 ? 1 : 0;
}
