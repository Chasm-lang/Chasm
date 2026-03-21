#pragma once
/* chasm_rl_shim.h — maps chasm_*(ctx, ...) calls to rl_*(...) functions.
   The self-hosted codegen emits chasm_<funcname>(ctx, args). For raylib
   bindings the codegen doesn't know the extern mapping, so we bridge here. */
#include "chasm_rl.h"

/* ---- Window / system ------------------------------------------------------- */
#define chasm_screen_w(ctx)           rl_screen_width()
#define chasm_screen_h(ctx)           rl_screen_height()
#define chasm_set_fps(ctx, fps)       rl_set_target_fps(fps)
#define chasm_set_title(ctx, t)       rl_set_window_title(t)
#define chasm_fps(ctx)                rl_fps()
#define chasm_dt(ctx)                 rl_frame_time()
#define chasm_time(ctx)               rl_time()

/* ---- Drawing --------------------------------------------------------------- */
#define chasm_clear(ctx, c)                        rl_clear_background(c)
#define chasm_draw_rect(ctx, x, y, w, h, c)        rl_draw_rectangle(x, y, w, h, c)
#define chasm_draw_rect_lines(ctx, x, y, w, h, c)  rl_draw_rectangle_lines(x, y, w, h, c)
#define chasm_draw_rect_rounded(ctx, x, y, w, h, r, s, c) rl_draw_rectangle_rounded(x, y, w, h, r, s, c)
#define chasm_draw_circle(ctx, x, y, r, c)         rl_draw_circle(x, y, r, c)
#define chasm_draw_circle_lines(ctx, x, y, r, c)   rl_draw_circle_lines(x, y, r, c)
#define chasm_draw_line(ctx, x1, y1, x2, y2, c)    rl_draw_line(x1, y1, x2, y2, c)
#define chasm_draw_line_ex(ctx, x1, y1, x2, y2, t, c) rl_draw_line_ex(x1, y1, x2, y2, t, c)
#define chasm_draw_text(ctx, text, x, y, sz, c)    rl_draw_text(text, x, y, sz, c)
#define chasm_measure_text(ctx, text, sz)           rl_measure_text(text, sz)
#define chasm_draw_fps(ctx, x, y)                   rl_draw_fps(x, y)

/* ---- Texture --------------------------------------------------------------- */
#define chasm_load_texture(ctx, p)              rl_load_texture(p)
#define chasm_unload_texture(ctx, h)            rl_unload_texture(h)
#define chasm_draw_texture(ctx, h, x, y, t)    rl_draw_texture(h, x, y, t)
#define chasm_draw_texture_ex(ctx, h, x, y, r, s, t) rl_draw_texture_ex(h, x, y, r, s, t)
#define chasm_draw_texture_rect(ctx, h, sx, sy, sw, sh, dx, dy, t) rl_draw_texture_rec(h, sx, sy, sw, sh, dx, dy, t)
#define chasm_texture_w(ctx, h)                 rl_texture_width(h)
#define chasm_texture_h(ctx, h)                 rl_texture_height(h)

/* ---- Font ------------------------------------------------------------------ */
#define chasm_load_font(ctx, p)                       rl_load_font(p)
#define chasm_draw_text_ex(ctx, f, t, x, y, sz, sp, c) rl_draw_text_ex(f, t, x, y, sz, sp, c)

/* ---- Audio ----------------------------------------------------------------- */
#define chasm_init_audio(ctx)        rl_init_audio()
#define chasm_close_audio(ctx)       rl_close_audio()
#define chasm_load_sound(ctx, p)     rl_load_sound(p)
#define chasm_play_sound(ctx, h)     rl_play_sound(h)
#define chasm_stop_sound(ctx, h)     rl_stop_sound(h)
#define chasm_load_music(ctx, p)     rl_load_music(p)
#define chasm_play_music(ctx, h)     rl_play_music(h)
#define chasm_update_music(ctx, h)   rl_update_music(h)
#define chasm_stop_music(ctx, h)     rl_stop_music(h)

/* ---- Keyboard -------------------------------------------------------------- */
#define chasm_key_down(ctx, k)       rl_is_key_down(k)
#define chasm_key_pressed(ctx, k)    rl_is_key_pressed(k)
#define chasm_key_released(ctx, k)   rl_is_key_released(k)
#define chasm_key_up(ctx, k)         rl_is_key_up(k)
#define chasm_key_last(ctx)          rl_get_key_pressed()

/* ---- Mouse ----------------------------------------------------------------- */
#define chasm_mouse_x(ctx)           rl_mouse_x()
#define chasm_mouse_y(ctx)           rl_mouse_y()
#define chasm_mouse_dx(ctx)          rl_mouse_delta_x()
#define chasm_mouse_dy(ctx)          rl_mouse_delta_y()
#define chasm_mouse_down(ctx, b)     rl_is_mouse_down(b)
#define chasm_mouse_pressed(ctx, b)  rl_is_mouse_pressed(b)
#define chasm_mouse_released(ctx, b) rl_is_mouse_released(b)
#define chasm_mouse_wheel(ctx)       rl_mouse_wheel()
#define chasm_hide_cursor(ctx)       rl_hide_cursor()
#define chasm_show_cursor(ctx)       rl_show_cursor()

/* ---- Collision ------------------------------------------------------------- */
#define chasm_collide_rects(ctx, x1, y1, w1, h1, x2, y2, w2, h2) \
    rl_check_collision_recs(x1, y1, w1, h1, x2, y2, w2, h2)
#define chasm_collide_circles(ctx, x1, y1, r1, x2, y2, r2) \
    rl_check_collision_circles(x1, y1, r1, x2, y2, r2)
#define chasm_point_in_rect(ctx, px, py, rx, ry, rw, rh) \
    rl_check_collision_point_rec(px, py, rx, ry, rw, rh)
