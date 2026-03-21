/// Shared prelude injected into every Chasm compilation that targets the
/// Raylib engine.  Both the compiler (main.zig) and the LSP (server.zig)
/// import this so that engine API names are always defined during analysis.
pub const raylib_prelude: []const u8 =
    \\# ---- Window / system ---------------------------------------------------
    \\extern fn screen_w() -> int                                              = "rl_screen_width"
    \\extern fn screen_h() -> int                                              = "rl_screen_height"
    \\extern fn set_fps(fps: int) -> void                                      = "rl_set_target_fps"
    \\extern fn set_title(title: str) -> void                                  = "rl_set_window_title"
    \\extern fn fps() -> int                                                   = "rl_fps"
    \\extern fn dt() -> float                                                  = "rl_frame_time"
    \\extern fn time() -> float                                                = "rl_time"
    \\# ---- Draw --------------------------------------------------------------
    \\extern fn clear(color: int) -> void                                      = "rl_clear_background"
    \\extern fn draw_rect(x: float, y: float, w: float, h: float, color: int) -> void = "rl_draw_rectangle"
    \\extern fn draw_rect_lines(x: float, y: float, w: float, h: float, color: int) -> void = "rl_draw_rectangle_lines"
    \\extern fn draw_rect_rounded(x: float, y: float, w: float, h: float, r: float, seg: int, color: int) -> void = "rl_draw_rectangle_rounded"
    \\extern fn draw_circle(x: float, y: float, r: float, color: int) -> void = "rl_draw_circle"
    \\extern fn draw_circle_lines(x: float, y: float, r: float, color: int) -> void = "rl_draw_circle_lines"
    \\extern fn draw_line(x1: float, y1: float, x2: float, y2: float, color: int) -> void = "rl_draw_line"
    \\extern fn draw_line_ex(x1: float, y1: float, x2: float, y2: float, thick: float, color: int) -> void = "rl_draw_line_ex"
    \\extern fn draw_text(text: str, x: float, y: float, size: int, color: int) -> void = "rl_draw_text"
    \\extern fn measure_text(text: str, size: int) -> float                   = "rl_measure_text"
    \\extern fn draw_fps(x: float, y: float) -> void                          = "rl_draw_fps"
    \\# ---- Texture -----------------------------------------------------------
    \\extern fn load_texture(path: str) -> int                                 = "rl_load_texture"
    \\extern fn unload_texture(handle: int) -> void                            = "rl_unload_texture"
    \\extern fn draw_texture(handle: int, x: float, y: float, tint: int) -> void = "rl_draw_texture"
    \\extern fn draw_texture_ex(handle: int, x: float, y: float, rot: float, scale: float, tint: int) -> void = "rl_draw_texture_ex"
    \\extern fn draw_texture_rect(handle: int, sx: float, sy: float, sw: float, sh: float, dx: float, dy: float, tint: int) -> void = "rl_draw_texture_rec"
    \\extern fn texture_w(handle: int) -> int                                  = "rl_texture_width"
    \\extern fn texture_h(handle: int) -> int                                  = "rl_texture_height"
    \\# ---- Font --------------------------------------------------------------
    \\extern fn load_font(path: str) -> int                                    = "rl_load_font"
    \\extern fn draw_text_ex(font: int, text: str, x: float, y: float, size: float, spacing: float, color: int) -> void = "rl_draw_text_ex"
    \\# ---- Audio -------------------------------------------------------------
    \\extern fn init_audio() -> void                                           = "rl_init_audio"
    \\extern fn close_audio() -> void                                          = "rl_close_audio"
    \\extern fn load_sound(path: str) -> int                                   = "rl_load_sound"
    \\extern fn play_sound(handle: int) -> void                                = "rl_play_sound"
    \\extern fn stop_sound(handle: int) -> void                                = "rl_stop_sound"
    \\extern fn load_music(path: str) -> int                                   = "rl_load_music"
    \\extern fn play_music(handle: int) -> void                                = "rl_play_music"
    \\extern fn update_music(handle: int) -> void                              = "rl_update_music"
    \\extern fn stop_music(handle: int) -> void                                = "rl_stop_music"
    \\# ---- Keyboard ----------------------------------------------------------
    \\extern fn key_down(key: int) -> bool                                     = "rl_is_key_down"
    \\extern fn key_pressed(key: int) -> bool                                  = "rl_is_key_pressed"
    \\extern fn key_released(key: int) -> bool                                 = "rl_is_key_released"
    \\extern fn key_up(key: int) -> bool                                       = "rl_is_key_up"
    \\extern fn key_last() -> int                                              = "rl_get_key_pressed"
    \\# ---- Mouse -------------------------------------------------------------
    \\extern fn mouse_x() -> float                                             = "rl_mouse_x"
    \\extern fn mouse_y() -> float                                             = "rl_mouse_y"
    \\extern fn mouse_dx() -> float                                            = "rl_mouse_delta_x"
    \\extern fn mouse_dy() -> float                                            = "rl_mouse_delta_y"
    \\extern fn mouse_down(btn: int) -> bool                                   = "rl_is_mouse_down"
    \\extern fn mouse_pressed(btn: int) -> bool                                = "rl_is_mouse_pressed"
    \\extern fn mouse_released(btn: int) -> bool                               = "rl_is_mouse_released"
    \\extern fn mouse_wheel() -> float                                         = "rl_mouse_wheel"
    \\extern fn hide_cursor() -> void                                          = "rl_hide_cursor"
    \\extern fn show_cursor() -> void                                          = "rl_show_cursor"
    \\# ---- Collision ---------------------------------------------------------
    \\extern fn collide_rects(x1: float, y1: float, w1: float, h1: float, x2: float, y2: float, w2: float, h2: float) -> bool = "rl_check_collision_recs"
    \\extern fn collide_circles(x1: float, y1: float, r1: float, x2: float, y2: float, r2: float) -> bool = "rl_check_collision_circles"
    \\extern fn point_in_rect(px: float, py: float, rx: float, ry: float, rw: float, rh: float) -> bool = "rl_check_collision_point_rec"
    \\
;
