/* engine/chasm_rl_exports.c — exports chasm_*(ctx,...) shim functions as
 * real (non-inline) symbols so the script .dylib can resolve them at dlopen
 * time via the engine binary's symbol table.
 *
 * Compiled into the engine binary alongside main.c.
 * The script dylib does NOT need to link against raylib directly.
 *
 * NOTE: We do NOT use the #define static / #define inline trick here because
 * chasm_rl.h defines chasm_rl_handles[] and chasm_rl_next as statics — stripping
 * 'static' would create duplicate global symbols with main.c and corrupt the
 * handle table. Instead we include chasm_rl.h normally (keeping its statics)
 * and write explicit non-inline wrappers that call the rl_* functions.
 */
#include "chasm_rl.h"
#include "chasm_rt.h"
#include <stdint.h>
#include <stdbool.h>

/* ---- Window / system ------------------------------------------------------- */
int64_t chasm_screen_w(ChasmCtx *ctx)                    { (void)ctx; return rl_screen_width(); }
int64_t chasm_screen_h(ChasmCtx *ctx)                    { (void)ctx; return rl_screen_height(); }
void    chasm_set_fps(ChasmCtx *ctx, int64_t fps)        { (void)ctx; rl_set_target_fps(fps); }
void    chasm_set_title(ChasmCtx *ctx, const char *t)    { (void)ctx; rl_set_window_title(t); }
int64_t chasm_fps(ChasmCtx *ctx)                         { (void)ctx; return rl_fps(); }
double  chasm_dt(ChasmCtx *ctx)                          { (void)ctx; return rl_frame_time(); }
double  chasm_time(ChasmCtx *ctx)                        { (void)ctx; return rl_time(); }

/* ---- Drawing --------------------------------------------------------------- */
void chasm_clear(ChasmCtx *ctx, int64_t c)               { (void)ctx; rl_clear_background(c); }
void chasm_draw_rect(ChasmCtx *ctx, double x, double y, double w, double h, int64_t c)
    { (void)ctx; rl_draw_rectangle(x, y, w, h, c); }
void chasm_draw_rect_lines(ChasmCtx *ctx, double x, double y, double w, double h, int64_t c)
    { (void)ctx; rl_draw_rectangle_lines(x, y, w, h, c); }
void chasm_draw_rect_rounded(ChasmCtx *ctx, double x, double y, double w, double h, double r, int64_t s, int64_t c)
    { (void)ctx; rl_draw_rectangle_rounded(x, y, w, h, r, s, c); }
void chasm_draw_circle(ChasmCtx *ctx, double x, double y, double r, int64_t c)
    { (void)ctx; rl_draw_circle(x, y, r, c); }
void chasm_draw_circle_lines(ChasmCtx *ctx, double x, double y, double r, int64_t c)
    { (void)ctx; rl_draw_circle_lines(x, y, r, c); }
void chasm_draw_line(ChasmCtx *ctx, double x1, double y1, double x2, double y2, int64_t c)
    { (void)ctx; rl_draw_line(x1, y1, x2, y2, c); }
void chasm_draw_line_ex(ChasmCtx *ctx, double x1, double y1, double x2, double y2, double t, int64_t c)
    { (void)ctx; rl_draw_line_ex(x1, y1, x2, y2, t, c); }
void chasm_draw_text(ChasmCtx *ctx, const char *text, double x, double y, int64_t sz, int64_t c)
    { (void)ctx; rl_draw_text(text, x, y, sz, c); }
double chasm_measure_text(ChasmCtx *ctx, const char *text, int64_t sz)
    { (void)ctx; return rl_measure_text(text, sz); }
void chasm_draw_fps(ChasmCtx *ctx, double x, double y)
    { (void)ctx; rl_draw_fps(x, y); }

/* ---- Texture --------------------------------------------------------------- */
int64_t chasm_load_texture(ChasmCtx *ctx, const char *p)
    { (void)ctx; return rl_load_texture(p); }
void chasm_unload_texture(ChasmCtx *ctx, int64_t h)
    { (void)ctx; rl_unload_texture(h); }
void chasm_draw_texture(ChasmCtx *ctx, int64_t h, double x, double y, int64_t t)
    { (void)ctx; rl_draw_texture(h, x, y, t); }
void chasm_draw_texture_ex(ChasmCtx *ctx, int64_t h, double x, double y, double r, double s, int64_t t)
    { (void)ctx; rl_draw_texture_ex(h, x, y, r, s, t); }
void chasm_draw_texture_rect(ChasmCtx *ctx, int64_t h, double sx, double sy, double sw, double sh, double dx, double dy, int64_t t)
    { (void)ctx; rl_draw_texture_rec(h, sx, sy, sw, sh, dx, dy, t); }
int64_t chasm_texture_w(ChasmCtx *ctx, int64_t h)
    { (void)ctx; return rl_texture_width(h); }
int64_t chasm_texture_h(ChasmCtx *ctx, int64_t h)
    { (void)ctx; return rl_texture_height(h); }

/* ---- Font ------------------------------------------------------------------ */
int64_t chasm_load_font(ChasmCtx *ctx, const char *p)
    { (void)ctx; return rl_load_font(p); }
void chasm_draw_text_ex(ChasmCtx *ctx, int64_t f, const char *t, double x, double y, double sz, double sp, int64_t c)
    { (void)ctx; rl_draw_text_ex(f, t, x, y, sz, sp, c); }

/* ---- Audio ----------------------------------------------------------------- */
void    chasm_init_audio(ChasmCtx *ctx)                  { (void)ctx; rl_init_audio(); }
void    chasm_close_audio(ChasmCtx *ctx)                 { (void)ctx; rl_close_audio(); }
int64_t chasm_load_sound(ChasmCtx *ctx, const char *p)   { (void)ctx; return rl_load_sound(p); }
void    chasm_play_sound(ChasmCtx *ctx, int64_t h)       { (void)ctx; rl_play_sound(h); }
void    chasm_stop_sound(ChasmCtx *ctx, int64_t h)       { (void)ctx; rl_stop_sound(h); }
int64_t chasm_load_music(ChasmCtx *ctx, const char *p)   { (void)ctx; return rl_load_music(p); }
void    chasm_play_music(ChasmCtx *ctx, int64_t h)       { (void)ctx; rl_play_music(h); }
void    chasm_update_music(ChasmCtx *ctx, int64_t h)     { (void)ctx; rl_update_music(h); }
void    chasm_stop_music(ChasmCtx *ctx, int64_t h)       { (void)ctx; rl_stop_music(h); }

/* ---- Keyboard -------------------------------------------------------------- */
bool    chasm_key_down(ChasmCtx *ctx, int64_t k)         { (void)ctx; return rl_is_key_down(k); }
bool    chasm_key_pressed(ChasmCtx *ctx, int64_t k)      { (void)ctx; return rl_is_key_pressed(k); }
bool    chasm_key_released(ChasmCtx *ctx, int64_t k)     { (void)ctx; return rl_is_key_released(k); }
bool    chasm_key_up(ChasmCtx *ctx, int64_t k)           { (void)ctx; return rl_is_key_up(k); }
int64_t chasm_key_last(ChasmCtx *ctx)                    { (void)ctx; return rl_get_key_pressed(); }

/* ---- Mouse ----------------------------------------------------------------- */
double chasm_mouse_x(ChasmCtx *ctx)                      { (void)ctx; return rl_mouse_x(); }
double chasm_mouse_y(ChasmCtx *ctx)                      { (void)ctx; return rl_mouse_y(); }
double chasm_mouse_dx(ChasmCtx *ctx)                     { (void)ctx; return rl_mouse_delta_x(); }
double chasm_mouse_dy(ChasmCtx *ctx)                     { (void)ctx; return rl_mouse_delta_y(); }
bool   chasm_mouse_down(ChasmCtx *ctx, int64_t b)        { (void)ctx; return rl_is_mouse_down(b); }
bool   chasm_mouse_pressed(ChasmCtx *ctx, int64_t b)     { (void)ctx; return rl_is_mouse_pressed(b); }
bool   chasm_mouse_released(ChasmCtx *ctx, int64_t b)    { (void)ctx; return rl_is_mouse_released(b); }
double chasm_mouse_wheel(ChasmCtx *ctx)                  { (void)ctx; return rl_mouse_wheel(); }
void   chasm_hide_cursor(ChasmCtx *ctx)                  { (void)ctx; rl_hide_cursor(); }
void   chasm_show_cursor(ChasmCtx *ctx)                  { (void)ctx; rl_show_cursor(); }

/* ---- Collision ------------------------------------------------------------- */
bool chasm_collide_rects(ChasmCtx *ctx, double x1, double y1, double w1, double h1,
                          double x2, double y2, double w2, double h2)
    { (void)ctx; return rl_check_collision_recs(x1, y1, w1, h1, x2, y2, w2, h2); }
bool chasm_collide_circles(ChasmCtx *ctx, double x1, double y1, double r1,
                            double x2, double y2, double r2)
    { (void)ctx; return rl_check_collision_circles(x1, y1, r1, x2, y2, r2); }
bool chasm_point_in_rect(ChasmCtx *ctx, double px, double py,
                          double rx, double ry, double rw, double rh)
    { (void)ctx; return rl_check_collision_point_rec(px, py, rx, ry, rw, rh); }

/* ---- Audio extended -------------------------------------------------------- */
bool   chasm_sound_playing(ChasmCtx *ctx, int64_t h)              { (void)ctx; return rl_sound_playing(h); }
void   chasm_sound_volume(ChasmCtx *ctx, int64_t h, double vol)   { (void)ctx; rl_sound_volume(h, vol); }
void   chasm_sound_pitch(ChasmCtx *ctx, int64_t h, double pitch)  { (void)ctx; rl_sound_pitch(h, pitch); }
void   chasm_pause_sound(ChasmCtx *ctx, int64_t h)                { (void)ctx; rl_pause_sound(h); }
void   chasm_resume_sound(ChasmCtx *ctx, int64_t h)               { (void)ctx; rl_resume_sound(h); }
bool   chasm_music_playing(ChasmCtx *ctx, int64_t h)              { (void)ctx; return rl_music_playing(h); }
void   chasm_music_volume(ChasmCtx *ctx, int64_t h, double vol)   { (void)ctx; rl_music_volume(h, vol); }
void   chasm_music_pitch(ChasmCtx *ctx, int64_t h, double pitch)  { (void)ctx; rl_music_pitch(h, pitch); }
double chasm_music_length(ChasmCtx *ctx, int64_t h)               { (void)ctx; return rl_music_length(h); }
double chasm_music_played(ChasmCtx *ctx, int64_t h)               { (void)ctx; return rl_music_played(h); }
void   chasm_pause_music(ChasmCtx *ctx, int64_t h)                { (void)ctx; rl_pause_music(h); }
void   chasm_resume_music(ChasmCtx *ctx, int64_t h)               { (void)ctx; rl_resume_music(h); }

/* ---- Window extended ------------------------------------------------------- */
bool  chasm_window_resized(ChasmCtx *ctx)                         { (void)ctx; return rl_window_resized(); }
void  chasm_set_window_size(ChasmCtx *ctx, int64_t w, int64_t h)  { (void)ctx; rl_set_window_size(w, h); }
void  chasm_toggle_fullscreen(ChasmCtx *ctx)                      { (void)ctx; rl_toggle_fullscreen(); }
bool  chasm_is_fullscreen(ChasmCtx *ctx)                          { (void)ctx; return rl_is_fullscreen(); }
bool  chasm_window_focused(ChasmCtx *ctx)                         { (void)ctx; return rl_window_focused(); }

/* ---- Drawing extended ------------------------------------------------------ */
void chasm_draw_triangle(ChasmCtx *ctx, double x1, double y1, double x2, double y2, double x3, double y3, int64_t c)
    { (void)ctx; rl_draw_triangle(x1, y1, x2, y2, x3, y3, c); }
void chasm_draw_triangle_lines(ChasmCtx *ctx, double x1, double y1, double x2, double y2, double x3, double y3, int64_t c)
    { (void)ctx; rl_draw_triangle_lines(x1, y1, x2, y2, x3, y3, c); }
void chasm_draw_ellipse(ChasmCtx *ctx, double cx, double cy, double rx, double ry, int64_t c)
    { (void)ctx; rl_draw_ellipse(cx, cy, rx, ry, c); }
void chasm_draw_ring(ChasmCtx *ctx, double cx, double cy, double inner, double outer, double start, double end, int64_t segs, int64_t c)
    { (void)ctx; rl_draw_ring(cx, cy, inner, outer, start, end, segs, c); }
void chasm_draw_poly(ChasmCtx *ctx, double cx, double cy, int64_t sides, double radius, double rot, int64_t c)
    { (void)ctx; rl_draw_poly(cx, cy, sides, radius, rot, c); }

/* ---- Texture extended ------------------------------------------------------ */
void chasm_draw_texture_tiled(ChasmCtx *ctx, int64_t h, double sx, double sy, double sw, double sh, double dx, double dy, double dw, double dh, int64_t tint)
    { (void)ctx; rl_draw_texture_tiled(h, sx, sy, sw, sh, dx, dy, dw, dh, tint); }
void chasm_set_texture_filter(ChasmCtx *ctx, int64_t h, int64_t filter)
    { (void)ctx; rl_set_texture_filter(h, filter); }

/* ---- Camera 2D ------------------------------------------------------------- */
void   chasm_camera2d_begin(ChasmCtx *ctx, double cx, double cy, double tx, double ty, double rot, double zoom)
    { (void)ctx; rl_camera2d_begin(cx, cy, tx, ty, rot, zoom); }
void   chasm_camera2d_end(ChasmCtx *ctx)
    { (void)ctx; rl_camera2d_end(); }
double chasm_world_to_screen_x(ChasmCtx *ctx, double wx, double wy, double cx, double cy, double tx, double ty, double rot, double zoom)
    { (void)ctx; return rl_world_to_screen_x(wx, wy, cx, cy, tx, ty, rot, zoom); }
double chasm_world_to_screen_y(ChasmCtx *ctx, double wx, double wy, double cx, double cy, double tx, double ty, double rot, double zoom)
    { (void)ctx; return rl_world_to_screen_y(wx, wy, cx, cy, tx, ty, rot, zoom); }

/* ---- Gamepad --------------------------------------------------------------- */
bool   chasm_gamepad_available(ChasmCtx *ctx, int64_t pad)                { (void)ctx; return rl_gamepad_available(pad); }
bool   chasm_gamepad_button_down(ChasmCtx *ctx, int64_t pad, int64_t btn) { (void)ctx; return rl_gamepad_button_down(pad, btn); }
bool   chasm_gamepad_button_pressed(ChasmCtx *ctx, int64_t pad, int64_t btn){ (void)ctx; return rl_gamepad_button_pressed(pad, btn); }
double chasm_gamepad_axis(ChasmCtx *ctx, int64_t pad, int64_t axis)       { (void)ctx; return rl_gamepad_axis(pad, axis); }

/* ---- Mouse extended -------------------------------------------------------- */
void chasm_set_mouse_pos(ChasmCtx *ctx, double x, double y) { (void)ctx; rl_set_mouse_pos(x, y); }
void chasm_mouse_cursor(ChasmCtx *ctx, int64_t cursor)      { (void)ctx; rl_mouse_cursor(cursor); }

/* ---- Clipboard ------------------------------------------------------------- */
const char *chasm_get_clipboard(ChasmCtx *ctx)              { (void)ctx; return rl_get_clipboard(); }
void        chasm_set_clipboard(ChasmCtx *ctx, const char *text) { (void)ctx; rl_set_clipboard(text); }

/* ---- Keyboard: key_code ---------------------------------------------------- */
int64_t chasm_key_code(ChasmCtx *ctx, const char *name) { (void)ctx; return rl_key_from_name(name); }

/* ---- Aliases (doc-friendly names) ----------------------------------------- */
void    chasm_clear_background(ChasmCtx *ctx, int64_t c)  { (void)ctx; rl_clear_background(c); }
void    chasm_draw_rectangle(ChasmCtx *ctx, double x, double y, double w, double h, int64_t c)
    { (void)ctx; rl_draw_rectangle(x, y, w, h, c); }
void    chasm_draw_rectangle_lines(ChasmCtx *ctx, double x, double y, double w, double h, int64_t c)
    { (void)ctx; rl_draw_rectangle_lines(x, y, w, h, c); }
void    chasm_draw_circle_v(ChasmCtx *ctx, double cx, double cy, double r, int64_t c)
    { (void)ctx; rl_draw_circle(cx, cy, r, c); }
int64_t chasm_screen_width(ChasmCtx *ctx)                 { (void)ctx; return rl_screen_width(); }
int64_t chasm_screen_height(ChasmCtx *ctx)                { (void)ctx; return rl_screen_height(); }

/* NOTE: chasm_abs, chasm_sqrt, chasm_sin, chasm_cos, etc. are static inline in
 * chasm_rt.h — each TU (including the script dylib) gets its own copy.
 * Do NOT export them here; that would create duplicate symbol conflicts. */
