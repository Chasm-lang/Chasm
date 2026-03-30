#pragma once
/* Chasm runtime — minimal arena allocator C header */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t *base;
    size_t   used;
    size_t   cap;
} ChasmArena;

/* Frame-heap tracker: malloc'd blocks (arrays, builders) are tracked inside
 * the frame arena buffer itself (last sizeof(_ChasmFH) bytes), so ChasmCtx
 * stays ABI-stable — its layout is always exactly three ChasmArena fields.
 *
 * Call chasm_ctx_init_gc(ctx) once after setting up ctx->frame to reserve
 * the GC region.  512 slots covers the vast majority of real games. */
#define CHASM_FRAME_HEAP_CAP 512

typedef struct {
    ChasmArena frame;
    ChasmArena script;
    ChasmArena persistent;
} ChasmCtx;

/* GC bookkeeping stored at the END of the frame buffer (last sizeof bytes).
 * Layout: void *ptrs[512] then int32_t count + int32_t _pad = 4104 bytes. */
typedef struct {
    void    *ptrs[CHASM_FRAME_HEAP_CAP]; /* 512 * 8 = 4096 bytes */
    int32_t  count;                       /* 4 bytes               */
    int32_t  _pad;                        /* 4 bytes (align total to 8) */
} _ChasmFH;                               /* sizeof = 4104 bytes   */

static inline void *chasm_alloc(ChasmArena *a, size_t n, size_t align) {
    size_t adj = (align - (a->used & (align - 1))) & (align - 1);
    size_t need = a->used + adj + n;
    if (need > a->cap) {
        fprintf(stderr, "chasm: arena overflow (used=%zu, need=%zu, cap=%zu)\n",
                a->used, need, a->cap);
        abort();
    }
    a->used += adj;
    void *p = a->base + a->used;
    a->used += n;
    return p;
}

/* Access the GC header embedded just past the end of the user alloc region. */
static inline _ChasmFH *_chasm_fh(ChasmCtx *ctx) {
    return (_ChasmFH *)(ctx->frame.base + ctx->frame.cap);
}

/* Call once after populating ctx->frame.{base,cap} to carve out the GC region.
 * Reduces frame.cap by sizeof(_ChasmFH) and zeroes the header. */
static inline void chasm_ctx_init_gc(ChasmCtx *ctx) {
    ctx->frame.cap -= sizeof(_ChasmFH);
    memset(_chasm_fh(ctx), 0, sizeof(_ChasmFH));
}

/* Register a malloc'd pointer for automatic free on chasm_clear_frame. */
static inline void chasm_fh_register(ChasmCtx *ctx, void *p) {
    _ChasmFH *fh = _chasm_fh(ctx);
    if (p && fh->count < CHASM_FRAME_HEAP_CAP)
        fh->ptrs[fh->count++] = p;
}

/* Return the number of pointers currently tracked (useful for testing). */
static inline int chasm_fh_count(ChasmCtx *ctx) {
    return _chasm_fh(ctx)->count;
}

static inline void chasm_clear_frame(ChasmCtx *ctx) {
    _ChasmFH *fh = _chasm_fh(ctx);
    for (int i = 0; i < fh->count; i++) { free(fh->ptrs[i]); fh->ptrs[i] = NULL; }
    fh->count = 0;
#ifdef CHASM_DEBUG
    /* Poison freed frame memory so stale reads produce garbage, not silently
     * valid-looking data.  0xCD is the classic "uninitialized" sentinel. */
    memset(ctx->frame.base, 0xCD, ctx->frame.used);
#endif
    ctx->frame.used = 0;
}

/* Promote a scalar value to a longer-lived arena (primitive: no-op copy). */
#define chasm_promote_scalar(val) (val)

/* Scalar copy macros — no-ops since codegen emits chasm_str_to_script /
 * chasm_str_to_persistent explicitly for string attrs. */
#define chasm_copy_to_script(ctx, val) (val)
#define chasm_persist_copy(ctx, val, ...) (val)

/* String-specific promotion: copy a frame-arena string into a longer-lived arena. */
static inline const char *chasm_str_to_script(ChasmCtx *ctx, const char *s) {
    if (!s) return "";
    size_t n = strlen(s);
    char *o = (char *)chasm_alloc(&ctx->script, n + 1, 1);
    if (!o) return s; /* arena full — return as-is (best effort) */
    memcpy(o, s, n + 1);
    return o;
}
static inline const char *chasm_str_to_persistent(ChasmCtx *ctx, const char *s) {
    if (!s) return "";
    size_t n = strlen(s);
    char *o = (char *)chasm_alloc(&ctx->persistent, n + 1, 1);
    if (!o) return s;
    memcpy(o, s, n + 1);
    return o;
}

/* ------------------------------------------------------------------ */
/* Chasm standard library                                             */
/* ------------------------------------------------------------------ */
#include <math.h>
#include <time.h>

/* ---- math -------------------------------------------------------- */
static inline double chasm_scale(ChasmCtx *ctx, double v, double f)          { (void)ctx; return v * f; }
static inline double chasm_clamp(ChasmCtx *ctx, double v, double lo, double hi) { (void)ctx; return v < lo ? lo : v > hi ? hi : v; }
static inline double chasm_abs(ChasmCtx *ctx, double v)                      { (void)ctx; return fabs(v); }
static inline double chasm_sqrt(ChasmCtx *ctx, double v)                     { (void)ctx; return sqrt(v); }
static inline double chasm_pow(ChasmCtx *ctx, double b, double e)            { (void)ctx; return pow(b, e); }
static inline double chasm_floor(ChasmCtx *ctx, double v)                    { (void)ctx; return floor(v); }
static inline double chasm_ceil(ChasmCtx *ctx, double v)                     { (void)ctx; return ceil(v); }
static inline double chasm_round(ChasmCtx *ctx, double v)                    { (void)ctx; return round(v); }
static inline double chasm_lerp(ChasmCtx *ctx, double a, double b, double t) { (void)ctx; return a + (b - a) * t; }
static inline double chasm_sign(ChasmCtx *ctx, double v)                     { (void)ctx; return v > 0 ? 1.0 : v < 0 ? -1.0 : 0.0; }
static inline double chasm_sin(ChasmCtx *ctx, double v)                      { (void)ctx; return sin(v); }
static inline double chasm_cos(ChasmCtx *ctx, double v)                      { (void)ctx; return cos(v); }
static inline double chasm_tan(ChasmCtx *ctx, double v)                      { (void)ctx; return tan(v); }
static inline double chasm_atan2(ChasmCtx *ctx, double y, double x)          { (void)ctx; return atan2(y, x); }
static inline double chasm_min(ChasmCtx *ctx, double a, double b)            { (void)ctx; return a < b ? a : b; }
static inline double chasm_max(ChasmCtx *ctx, double a, double b)            { (void)ctx; return a > b ? a : b; }
static inline double chasm_deg_to_rad(ChasmCtx *ctx, double d)               { (void)ctx; return d * (3.14159265358979323846 / 180.0); }
static inline double chasm_rad_to_deg(ChasmCtx *ctx, double r)               { (void)ctx; return r * (180.0 / 3.14159265358979323846); }
static inline double chasm_fract(ChasmCtx *ctx, double v)                    { (void)ctx; return v - floor(v); }
static inline double chasm_wrap(ChasmCtx *ctx, double v, double lo, double hi) {
    (void)ctx; double r = hi - lo; if (r == 0) return lo;
    return v - r * floor((v - lo) / r);
}
static inline double chasm_snap(ChasmCtx *ctx, double v, double step)        { (void)ctx; return step == 0 ? v : floor(v / step + 0.5) * step; }
static inline double chasm_smooth_step(ChasmCtx *ctx, double e0, double e1, double x) {
    (void)ctx; double t = (x-e0)/(e1-e0); t = t<0?0:t>1?1:t;
    return t*t*(3-2*t);
}
static inline double chasm_smoother_step(ChasmCtx *ctx, double e0, double e1, double x) {
    (void)ctx; double t = (x-e0)/(e1-e0); t = t<0?0:t>1?1:t;
    return t*t*t*(t*(t*6-15)+10);
}
static inline double chasm_ping_pong(ChasmCtx *ctx, double t, double len) {
    (void)ctx; if (len == 0) return 0;
    double v = fmod(t, 2*len); if (v < 0) v += 2*len;
    return v <= len ? v : 2*len - v;
}
static inline double chasm_move_toward(ChasmCtx *ctx, double cur, double target, double delta) {
    (void)ctx; double d = target - cur;
    return fabs(d) <= delta ? target : cur + (d > 0 ? delta : -delta);
}
static inline double chasm_angle_diff(ChasmCtx *ctx, double a, double b) {
    (void)ctx; double d = fmod(b - a + 3.14159265358979323846, 6.28318530717958647692) - 3.14159265358979323846;
    return d < -3.14159265358979323846 ? d + 6.28318530717958647692 : d;
}

/* ---- easing ------------------------------------------------------ */
static inline double chasm_ease_in(ChasmCtx *ctx, double t)          { (void)ctx; t=t<0?0:t>1?1:t; return t*t; }
static inline double chasm_ease_out(ChasmCtx *ctx, double t)         { (void)ctx; t=t<0?0:t>1?1:t; return 1-(1-t)*(1-t); }
static inline double chasm_ease_in_out(ChasmCtx *ctx, double t)      { (void)ctx; t=t<0?0:t>1?1:t; return t<0.5?2*t*t:1-2*(1-t)*(1-t); }
static inline double chasm_ease_in_cubic(ChasmCtx *ctx, double t)    { (void)ctx; t=t<0?0:t>1?1:t; return t*t*t; }
static inline double chasm_ease_out_cubic(ChasmCtx *ctx, double t)   { (void)ctx; t=t<0?0:t>1?1:t; return 1-(1-t)*(1-t)*(1-t); }
static inline double chasm_ease_in_out_cubic(ChasmCtx *ctx, double t) {
    (void)ctx; t=t<0?0:t>1?1:t;
    return t<0.5 ? 4*t*t*t : 1-4*(1-t)*(1-t)*(1-t);
}
static inline double chasm_ease_in_elastic(ChasmCtx *ctx, double t) {
    (void)ctx; if(t<=0)return 0; if(t>=1)return 1;
    return -pow(2,10*t-10)*sin((t*10-10.75)*6.28318530717958647692/3.0);
}
static inline double chasm_ease_out_bounce(ChasmCtx *ctx, double t) {
    (void)ctx; if(t<1/2.75) return 7.5625*t*t;
    if(t<2/2.75){t-=1.5/2.75;return 7.5625*t*t+0.75;}
    if(t<2.5/2.75){t-=2.25/2.75;return 7.5625*t*t+0.9375;}
    t-=2.625/2.75; return 7.5625*t*t+0.984375;
}

/* ---- vec2 (flat: pass x,y as separate floats) -------------------- */
static inline double chasm_vec2_len(ChasmCtx *ctx, double x, double y)                   { (void)ctx; return sqrt(x*x+y*y); }
static inline double chasm_vec2_dot(ChasmCtx *ctx, double ax, double ay, double bx, double by) { (void)ctx; return ax*bx+ay*by; }
static inline double chasm_vec2_dist(ChasmCtx *ctx, double ax, double ay, double bx, double by) { return chasm_vec2_len(ctx, bx-ax, by-ay); }
static inline double chasm_vec2_angle(ChasmCtx *ctx, double x, double y)                 { (void)ctx; return atan2(y, x); }
static inline double chasm_vec2_cross(ChasmCtx *ctx, double ax, double ay, double bx, double by) { (void)ctx; return ax*by - ay*bx; }
static inline double chasm_vec2_norm_x(ChasmCtx *ctx, double x, double y) {
    (void)ctx; double l = sqrt(x*x+y*y); return l==0?0:x/l;
}
static inline double chasm_vec2_norm_y(ChasmCtx *ctx, double x, double y) {
    (void)ctx; double l = sqrt(x*x+y*y); return l==0?0:y/l;
}

/* ---- bitwise ----------------------------------------------------- */
static inline int64_t chasm_bit_and(ChasmCtx *ctx, int64_t a, int64_t b) { (void)ctx; return a & b; }
static inline int64_t chasm_bit_or (ChasmCtx *ctx, int64_t a, int64_t b) { (void)ctx; return a | b; }
static inline int64_t chasm_bit_xor(ChasmCtx *ctx, int64_t a, int64_t b) { (void)ctx; return a ^ b; }
static inline int64_t chasm_bit_not(ChasmCtx *ctx, int64_t a)            { (void)ctx; return ~a; }
static inline int64_t chasm_bit_shl(ChasmCtx *ctx, int64_t a, int64_t n) { (void)ctx; return a << (n & 63); }
static inline int64_t chasm_bit_shr(ChasmCtx *ctx, int64_t a, int64_t n) { (void)ctx; return a >> (n & 63); }

/* ---- random ------------------------------------------------------ */
/* Seed once on first call via a static flag. */
static inline double chasm_rand(ChasmCtx *ctx) {
    static int seeded = 0; (void)ctx;
    if (!seeded) { srand((unsigned)time(NULL)); seeded = 1; }
    return (double)rand() / ((double)RAND_MAX + 1.0);
}
static inline double chasm_rand_range(ChasmCtx *ctx, double lo, double hi) {
    return lo + chasm_rand(ctx) * (hi - lo);
}
static inline int64_t chasm_rand_int(ChasmCtx *ctx, int64_t lo, int64_t hi) {
    if (hi <= lo) return lo;
    return lo + (int64_t)(chasm_rand(ctx) * (double)(hi - lo));
}

/* ---- string ------------------------------------------------------ */
static inline int64_t     chasm_str_len(ChasmCtx *ctx, const char *s) { (void)ctx; return s ? (int64_t)strlen(s) : 0; }
static inline const char *chasm_str_concat(ChasmCtx *ctx, const char *a, const char *b) {
    if (!a) a=""; if (!b) b="";
    size_t la=strlen(a), lb=strlen(b);
    char *o=(char*)chasm_alloc(&ctx->frame,la+lb+1,1); if(!o)return "";
    memcpy(o,a,la); memcpy(o+la,b,lb); o[la+lb]='\0'; return o;
}
static inline const char *chasm_str_repeat(ChasmCtx *ctx, const char *s, int64_t n) {
    if (!s||n<=0) return "";
    size_t l=strlen(s); char *o=(char*)chasm_alloc(&ctx->frame,l*(size_t)n+1,1); if(!o)return "";
    for(int64_t i=0;i<n;i++) memcpy(o+i*l,s,l); o[l*n]='\0'; return o;
}
static inline const char *chasm_str_slice(ChasmCtx *ctx, const char *s, int64_t start, int64_t end) {
    if (!s) return "";
    int64_t l=(int64_t)strlen(s);
    if(start<0)start=0; if(end>l)end=l; if(start>=end)return "";
    size_t n=(size_t)(end-start);
    char *o=(char*)chasm_alloc(&ctx->frame,n+1,1); if(!o)return "";
    memcpy(o,s+start,n); o[n]='\0'; return o;
}
static inline int64_t     chasm_str_char_at(ChasmCtx *ctx, const char *s, int64_t i) { (void)ctx; if(!s)return 0; int64_t l=(int64_t)strlen(s); if(i<0||i>=l)return 0; return (uint8_t)s[i]; }
static inline const char *chasm_str_from_char(ChasmCtx *ctx, int64_t c) {
    char *o=(char*)chasm_alloc(&ctx->frame,2,1); if(!o)return "";
    o[0]=(char)c; o[1]='\0'; return o;
}
static inline const char *chasm_str_upper(ChasmCtx *ctx, const char *s) {
    if (!s) return "";
    size_t l=strlen(s); char *o=(char*)chasm_alloc(&ctx->frame,l+1,1); if(!o)return "";
    for(size_t i=0;i<=l;i++) o[i]=(char)(s[i]>='a'&&s[i]<='z'?s[i]-32:s[i]); return o;
}
static inline const char *chasm_str_lower(ChasmCtx *ctx, const char *s) {
    if (!s) return "";
    size_t l=strlen(s); char *o=(char*)chasm_alloc(&ctx->frame,l+1,1); if(!o)return "";
    for(size_t i=0;i<=l;i++) o[i]=(char)(s[i]>='A'&&s[i]<='Z'?s[i]+32:s[i]); return o;
}
static inline const char *chasm_str_trim(ChasmCtx *ctx, const char *s) {
    if (!s) return "";
    while(*s==' '||*s=='\t'||*s=='\n'||*s=='\r') s++;
    size_t l=strlen(s);
    while(l>0&&(s[l-1]==' '||s[l-1]=='\t'||s[l-1]=='\n'||s[l-1]=='\r')) l--;
    char *o=(char*)chasm_alloc(&ctx->frame,l+1,1); if(!o)return "";
    memcpy(o,s,l); o[l]='\0'; return o;
}
static inline bool        chasm_str_contains(ChasmCtx *ctx, const char *s, const char *sub)    { (void)ctx; return s&&sub&&strstr(s,sub)!=NULL; }
static inline bool        chasm_str_starts_with(ChasmCtx *ctx, const char *s, const char *pre) { (void)ctx; if(!s||!pre)return 0; return strncmp(s,pre,strlen(pre))==0; }
static inline bool        chasm_str_ends_with(ChasmCtx *ctx, const char *s, const char *suf)   {
    (void)ctx; if(!s||!suf)return 0;
    size_t ls=strlen(s),lx=strlen(suf); return ls>=lx&&memcmp(s+ls-lx,suf,lx)==0;
}
static inline bool        chasm_str_eq(ChasmCtx *ctx, const char *a, const char *b) { (void)ctx; return a&&b&&strcmp(a,b)==0; }
static inline const char *chasm_int_to_str(ChasmCtx *ctx, int64_t v) {
    char *b=(char*)chasm_alloc(&ctx->frame,24,1); if(!b)return "";
    snprintf(b,24,"%lld",(long long)v); return b;
}
static inline const char *chasm_float_to_str(ChasmCtx *ctx, double v) {
    char *b=(char*)chasm_alloc(&ctx->frame,32,1); if(!b)return "";
    snprintf(b,32,"%g",v); return b;
}
static inline const char *chasm_bool_to_str(ChasmCtx *ctx, bool v) { (void)ctx; return v ? "true" : "false"; }

/* ---- type conversion --------------------------------------------- */
static inline int64_t chasm_to_int(ChasmCtx *ctx, double v)   { (void)ctx; return (int64_t)v; }
static inline double  chasm_to_float(ChasmCtx *ctx, int64_t v){ (void)ctx; return (double)v; }
static inline bool    chasm_to_bool(ChasmCtx *ctx, int64_t v) { (void)ctx; return v != 0; }

/* ---- color (packed 0xRRGGBBAA) ----------------------------------- */
static inline int64_t chasm_rgb(ChasmCtx *ctx, int64_t r, int64_t g, int64_t b)           { (void)ctx; return ((r&0xFF)<<24)|((g&0xFF)<<16)|((b&0xFF)<<8)|0xFF; }
static inline int64_t chasm_rgba(ChasmCtx *ctx, int64_t r, int64_t g, int64_t b, int64_t a){ (void)ctx; return ((r&0xFF)<<24)|((g&0xFF)<<16)|((b&0xFF)<<8)|(a&0xFF); }
static inline int64_t chasm_color_r(ChasmCtx *ctx, int64_t c) { (void)ctx; return (c>>24)&0xFF; }
static inline int64_t chasm_color_g(ChasmCtx *ctx, int64_t c) { (void)ctx; return (c>>16)&0xFF; }
static inline int64_t chasm_color_b(ChasmCtx *ctx, int64_t c) { (void)ctx; return (c>>8)&0xFF; }
static inline int64_t chasm_color_a(ChasmCtx *ctx, int64_t c) { (void)ctx; return c&0xFF; }
static inline int64_t chasm_color_lerp(ChasmCtx *ctx, int64_t a, int64_t b, double t) {
    int64_t ar=(a>>24)&0xFF, ag=(a>>16)&0xFF, ab=(a>>8)&0xFF, aa=a&0xFF;
    int64_t br=(b>>24)&0xFF, bg=(b>>16)&0xFF, bb=(b>>8)&0xFF, ba=b&0xFF;
    int64_t r=(int64_t)(ar+(br-ar)*t), g=(int64_t)(ag+(bg-ag)*t);
    int64_t bl2=(int64_t)(ab+(bb-ab)*t), al=(int64_t)(aa+(ba-aa)*t);
    return ((r&0xFF)<<24)|((g&0xFF)<<16)|((bl2&0xFF)<<8)|(al&0xFF);
}
static inline int64_t chasm_color_mix(ChasmCtx *ctx, int64_t a, int64_t b, double t) { return chasm_color_lerp(ctx,a,b,t); }

/* ---- time -------------------------------------------------------- */
static inline double  chasm_time_now(ChasmCtx *ctx) { (void)ctx; struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); return (double)ts.tv_sec+(double)ts.tv_nsec*1e-9; }
static inline int64_t chasm_time_ms(ChasmCtx *ctx)  { (void)ctx; struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); return (int64_t)ts.tv_sec*1000+ts.tv_nsec/1000000; }

/* ---- arrays ------------------------------------------------------ */
/* elem_size stores the element byte-size for typed (struct) arrays.
 * Scalar int/bool arrays use elem_size=8; float arrays use elem_size=8.
 * Struct arrays use elem_size=sizeof(Struct); codegen emits typed wrappers
 * (chasm_array_get_Foo, chasm_array_set_Foo, chasm_array_push_Foo) that
 * delegate to the raw ops below. */
typedef struct { void *data; int64_t len; int64_t cap; int64_t elem_size; } ChasmArray;

/* ---- scalar (int64_t) array ---------------------------------------- */
static inline ChasmArray chasm_array_new(ChasmCtx *ctx, int64_t cap) {
    if (cap <= 0) return (ChasmArray){NULL, 0, 0, 8};
    void *d = malloc((size_t)cap * 8);
    chasm_fh_register(ctx, d);  /* freed by chasm_clear_frame */
    return (ChasmArray){d, 0, cap, 8};
}
static inline void chasm_array_push(ChasmCtx *ctx, ChasmArray *a, int64_t v) {
    if (a->len >= a->cap) {
        a->cap = a->cap * 2 + 8;
        void *old = a->data;
        a->data = realloc(a->data, (size_t)a->cap * 8);
        if (a->data != old) {
            _ChasmFH *fh = _chasm_fh(ctx);
            for (int _i = 0; _i < fh->count; _i++)
                if (fh->ptrs[_i] == old) { fh->ptrs[_i] = a->data; break; }
        }
    }
    if (a->data) ((int64_t*)a->data)[a->len++] = v;
}
static inline int64_t chasm_array_pop (ChasmCtx *ctx, ChasmArray *a)                     { (void)ctx; return a->len>0?((int64_t*)a->data)[--a->len]:0; }
static inline int64_t chasm_array_get (ChasmCtx *ctx, ChasmArray *a, int64_t i)          { (void)ctx; return(i>=0&&i<a->len)?((int64_t*)a->data)[i]:0; }
static inline void    chasm_array_set (ChasmCtx *ctx, ChasmArray *a, int64_t i, int64_t v){ (void)ctx; if(i>=0&&i<a->len)((int64_t*)a->data)[i]=v; }
static inline int64_t chasm_array_len (ChasmCtx *ctx, ChasmArray *a)                     { (void)ctx; return a->len; }
static inline void    chasm_array_clear(ChasmCtx *ctx, ChasmArray *a)                    { (void)ctx; a->len=0; }

/* ---- string (const char*) array ----------------------------------- */
static inline ChasmArray chasm_array_new_s(ChasmCtx *ctx, int64_t cap) {
    if (cap <= 0) return (ChasmArray){NULL, 0, 0, (int64_t)sizeof(const char*)};
    void *d = malloc((size_t)cap * sizeof(const char*));
    chasm_fh_register(ctx, d);
    return (ChasmArray){d, 0, cap, (int64_t)sizeof(const char*)};
}
static inline void chasm_array_push_s(ChasmCtx *ctx, ChasmArray *a, const char *v) {
    if (a->len >= a->cap) {
        a->cap = a->cap * 2 + 8;
        void *old = a->data;
        a->data = realloc(a->data, (size_t)a->cap * sizeof(const char*));
        if (a->data != old) {
            _ChasmFH *fh = _chasm_fh(ctx);
            for (int _i = 0; _i < fh->count; _i++)
                if (fh->ptrs[_i] == old) { fh->ptrs[_i] = a->data; break; }
        }
    }
    if (a->data) ((const char**)a->data)[a->len++] = v;
}
static inline const char* chasm_array_get_s(ChasmCtx *ctx, ChasmArray *a, int64_t i) { (void)ctx; return (i>=0&&i<a->len)?((const char**)a->data)[i]:""; }
static inline void        chasm_array_set_s(ChasmCtx *ctx, ChasmArray *a, int64_t i, const char *v) { (void)ctx; if(i>=0&&i<a->len)((const char**)a->data)[i]=v; }
static inline const char* chasm_array_pop_s(ChasmCtx *ctx, ChasmArray *a) { (void)ctx; return a->len>0?((const char**)a->data)[--a->len]:""; }

/* ---- typed (struct) array ----------------------------------------- */
/* Constructor: pass sizeof(YourStruct) as elem_size.
 * Codegen emits per-struct wrappers that call these. */
static inline ChasmArray chasm_array_new_typed(ChasmCtx *ctx, int64_t cap, int64_t elem_size) {
    if (cap <= 0 || elem_size <= 0) return (ChasmArray){NULL, 0, 0, elem_size};
    void *d = malloc((size_t)cap * (size_t)elem_size);
    chasm_fh_register(ctx, d);
    return (ChasmArray){d, 0, cap, elem_size};
}

static inline void chasm_array_set_raw(ChasmArray *a, int64_t i, const void *val) {
    if (i >= 0 && i < a->len)
        memcpy((char*)a->data + (size_t)i * (size_t)a->elem_size, val,
               (size_t)a->elem_size);
}
static inline void chasm_array_get_raw(ChasmArray *a, int64_t i, void *out) {
    if (i >= 0 && i < a->len)
        memcpy(out, (char*)a->data + (size_t)i * (size_t)a->elem_size,
               (size_t)a->elem_size);
    else
        memset(out, 0, (size_t)a->elem_size);
}
static inline void chasm_array_push_raw(ChasmCtx *ctx, ChasmArray *a, const void *val) {
    if (a->len >= a->cap) {
        a->cap = a->cap * 2 + 8;
        void *old = a->data;
        a->data = realloc(a->data, (size_t)a->cap * (size_t)a->elem_size);
        if (a->data != old) {
            _ChasmFH *fh = _chasm_fh(ctx);
            for (int _i = 0; _i < fh->count; _i++)
                if (fh->ptrs[_i] == old) { fh->ptrs[_i] = a->data; break; }
        }
    }
    if (a->data) {
        memcpy((char*)a->data + (size_t)a->len * (size_t)a->elem_size, val,
               (size_t)a->elem_size);
        a->len++;
    }
}

/* ---- string builder ---------------------------------------------- */
typedef struct { char *buf; int64_t len; int64_t cap; } ChasmStrBuilder;
static inline ChasmStrBuilder chasm_str_builder_new(ChasmCtx *ctx) {
    char *buf = (char*)malloc(64);
    chasm_fh_register(ctx, buf);  /* freed by chasm_clear_frame */
    return (ChasmStrBuilder){buf, 0, 64};
}
static inline void chasm_str_builder_push(ChasmCtx *ctx, ChasmStrBuilder *b, int64_t c) {
    if (b->len >= b->cap) {
        char *old = b->buf; b->cap = b->cap*2+8;
        b->buf = (char*)realloc(b->buf, (size_t)b->cap);
        if (b->buf != old) {
            _ChasmFH *fh = _chasm_fh(ctx);
            for (int _i = 0; _i < fh->count; _i++)
                if (fh->ptrs[_i] == old) { fh->ptrs[_i] = b->buf; break; }
        }
    }
    if (b->buf) b->buf[b->len++] = (char)c;
}
static inline void chasm_str_builder_append(ChasmCtx *ctx, ChasmStrBuilder *b, const char *s) {
    if (!s) return;
    size_t sl = strlen(s);
    while ((size_t)b->len + sl > (size_t)b->cap) {
        char *old = b->buf; b->cap = b->cap*2+(int64_t)sl+8;
        b->buf = (char*)realloc(b->buf, (size_t)b->cap);
        if (b->buf != old) {
            _ChasmFH *fh = _chasm_fh(ctx);
            for (int _i = 0; _i < fh->count; _i++)
                if (fh->ptrs[_i] == old) { fh->ptrs[_i] = b->buf; break; }
        }
    }
    if (b->buf) { memcpy(b->buf + b->len, s, sl); b->len += (int64_t)sl; }
}
static inline const char *chasm_str_builder_build(ChasmCtx *ctx, ChasmStrBuilder *b) {
    if (!b || !b->buf) return "";
    char *out = (char*)chasm_alloc(&ctx->frame, (size_t)b->len + 1, 1);
    if (!out) return "";
    memcpy(out, b->buf, (size_t)b->len); out[b->len] = '\0'; return out;
}

/* ---- file i/o ---------------------------------------------------- */
static inline const char *chasm_file_read(ChasmCtx *ctx, const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return "";
    fseek(f, 0, SEEK_END); long sz = ftell(f); rewind(f);
    char *buf = (char*)chasm_alloc(&ctx->persistent, (size_t)sz + 1, 1);
    if (!buf) { fclose(f); return ""; }
    fread(buf, 1, (size_t)sz, f); buf[sz] = '\0';
    fclose(f); return buf;
}
static inline void chasm_file_write(ChasmCtx *ctx, const char *path, const char *content) {
    (void)ctx; if (!path || !content) return;
    FILE *f = fopen(path, "wb"); if (!f) return;
    fwrite(content, 1, strlen(content), f); fclose(f);
}
static inline bool chasm_file_exists(ChasmCtx *ctx, const char *path) {
    (void)ctx; if (!path) return false;
    FILE *f = fopen(path, "rb"); if (!f) return false;
    fclose(f); return true;
}

/* ---- tuples ------------------------------------------------------ */
typedef struct { int64_t v0; int64_t v1; }           ChasmTuple2;
typedef struct { int64_t v0; int64_t v1; int64_t v2; } ChasmTuple3;

/* ---- range ------------------------------------------------------- */
static inline ChasmArray chasm_range(ChasmCtx *ctx, int64_t lo, int64_t hi) {
    int64_t n = hi > lo ? hi - lo : 0;
    ChasmArray a = chasm_array_new(ctx, n > 0 ? n : 1);
    for (int64_t i = 0; i < n; i++) chasm_array_push(ctx, &a, lo + i);
    return a;
}

/* ---- i/o --------------------------------------------------------- */
static inline void chasm_print(ChasmCtx *ctx, int64_t v)       { (void)ctx; printf("%lld\n", (long long)v); }
static inline void chasm_print_f(ChasmCtx *ctx, double v)      { (void)ctx; printf("%g\n", v); }
static inline void chasm_print_s(ChasmCtx *ctx, const char *v) { (void)ctx; printf("%s\n", v ? v : "(nil)"); }
static inline void chasm_print_b(ChasmCtx *ctx, bool v)        { (void)ctx; printf("%s\n", v ? "true" : "false"); }
static inline void chasm_eprint(ChasmCtx *ctx, const char *s)  { (void)ctx; fprintf(stderr, "%s", s ? s : ""); }
static inline void chasm_eprint_nl(ChasmCtx *ctx, const char *s){ (void)ctx; fprintf(stderr, "%s\n", s ? s : ""); }
static inline void chasm_exit(ChasmCtx *ctx, int64_t code)     { (void)ctx; exit((int)code); }
static inline const char *chasm_getenv(ChasmCtx *ctx, const char *name) {
    (void)ctx; const char *v = getenv(name); return v ? v : "";
}
static inline void chasm_log(ChasmCtx *ctx, int64_t v)         { (void)ctx; fprintf(stderr, "[log] %lld\n", (long long)v); }
static inline void chasm_assert(ChasmCtx *ctx, bool cond) {
    (void)ctx; if (!cond) { fprintf(stderr, "chasm: assertion failed\n"); abort(); }
}
static inline void chasm_assert_eq(ChasmCtx *ctx, int64_t a, int64_t b) {
    (void)ctx; if (a != b) { fprintf(stderr, "chasm: assert_eq failed: %lld != %lld\n", (long long)a, (long long)b); abort(); }
}
static inline void chasm_todo(ChasmCtx *ctx) {
    (void)ctx; fprintf(stderr, "chasm: todo() reached\n"); abort();
}
