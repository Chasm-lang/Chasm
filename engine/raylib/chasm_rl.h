#pragma once
/* chasm_rl.h — Raylib adapter for Chasm scripts.
   Include BEFORE your compiled Chasm .c file.
   Functions use rl_ prefix and take NO ChasmCtx* — extern calls in Chasm
   codegen don't pass ctx, so these are thin wrappers around raylib directly. */
#include "raylib.h"
#include "chasm_rt.h"
#include <stdint.h>
#include <stdbool.h>

/* ---- Color -----------------------------------------------------------------
   Chasm represents colors as packed int64_t: 0xRRGGBBAA                      */
#define CHASM_TO_RL_COLOR(c) ((Color){                   \
    (unsigned char)(((int64_t)(c) >> 24) & 0xFF),        \
    (unsigned char)(((int64_t)(c) >> 16) & 0xFF),        \
    (unsigned char)(((int64_t)(c) >>  8) & 0xFF),        \
    (unsigned char)( (int64_t)(c)        & 0xFF)         \
})

/* ---- Handle table ----------------------------------------------------------
   Textures, Fonts, Sounds, and Music are opaque to Chasm scripts.
   Scripts receive an int64_t handle ID; the engine maps it to the real type.  */
#define CHASM_RL_MAX_HANDLES 1024
typedef enum {
    CHASM_RL_NONE = 0,
    CHASM_RL_TEXTURE,
    CHASM_RL_FONT,
    CHASM_RL_SOUND,
    CHASM_RL_MUSIC
} ChasmRlKind;

typedef struct {
    ChasmRlKind kind;
    union {
        Texture2D texture;
        Font      font;
        Sound     sound;
        Music     music;
    } data;
} ChasmRlHandle;

static ChasmRlHandle chasm_rl_handles[CHASM_RL_MAX_HANDLES];
static int64_t       chasm_rl_next = 1;

static inline int64_t chasm_rl_new(ChasmRlKind k) {
    if (chasm_rl_next >= CHASM_RL_MAX_HANDLES) return 0;
    int64_t id = chasm_rl_next++;
    chasm_rl_handles[id].kind = k;
    return id;
}

/* ---- Window ---------------------------------------------------------------- */
static inline void    rl_init_window(int64_t w, int64_t h, const char *title) { InitWindow((int)w, (int)h, title); }
static inline void    rl_set_target_fps(int64_t fps)  { SetTargetFPS((int)fps); }
static inline bool    rl_window_should_close(void)    { return WindowShouldClose(); }
static inline void    rl_close_window(void)           { CloseWindow(); }
static inline int64_t rl_screen_width(void)           { return (int64_t)GetScreenWidth(); }
static inline int64_t rl_screen_height(void)          { return (int64_t)GetScreenHeight(); }
static inline double  rl_frame_time(void)             { return (double)GetFrameTime(); }
static inline double  rl_time(void)                   { return (double)GetTime(); }
static inline int64_t rl_fps(void)                    { return (int64_t)GetFPS(); }
static inline void    rl_set_window_title(const char *title) { SetWindowTitle(title); }

/* ---- Drawing --------------------------------------------------------------- */
static inline void rl_begin_drawing(void)             { BeginDrawing(); }
static inline void rl_end_drawing(void)               { EndDrawing(); }
static inline void rl_clear_background(int64_t c)     { ClearBackground(CHASM_TO_RL_COLOR(c)); }

static inline void rl_draw_rectangle(double x, double y, double w, double h, int64_t c)
    { DrawRectangle((int)x, (int)y, (int)w, (int)h, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_rectangle_lines(double x, double y, double w, double h, int64_t c)
    { DrawRectangleLines((int)x, (int)y, (int)w, (int)h, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_rectangle_rounded(double x, double y, double w, double h, double r, int64_t seg, int64_t c)
    { DrawRectangleRounded((Rectangle){(float)x,(float)y,(float)w,(float)h}, (float)r, (int)seg, CHASM_TO_RL_COLOR(c)); }

static inline void rl_draw_circle(double x, double y, double r, int64_t c)
    { DrawCircle((int)x, (int)y, (float)r, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_circle_lines(double x, double y, double r, int64_t c)
    { DrawCircleLines((int)x, (int)y, (float)r, CHASM_TO_RL_COLOR(c)); }

static inline void rl_draw_line(double x1, double y1, double x2, double y2, int64_t c)
    { DrawLine((int)x1, (int)y1, (int)x2, (int)y2, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_line_ex(double x1, double y1, double x2, double y2, double thick, int64_t c)
    { DrawLineEx((Vector2){(float)x1,(float)y1}, (Vector2){(float)x2,(float)y2}, (float)thick, CHASM_TO_RL_COLOR(c)); }

static inline void rl_draw_text(const char *text, double x, double y, int64_t size, int64_t c)
    { DrawText(text, (int)x, (int)y, (int)size, CHASM_TO_RL_COLOR(c)); }
static inline double rl_measure_text(const char *text, int64_t size)
    { return (double)MeasureText(text, (int)size); }
static inline void rl_draw_fps(double x, double y)
    { DrawFPS((int)x, (int)y); }

/* ---- Texture --------------------------------------------------------------- */
static inline int64_t rl_load_texture(const char *path) {
    Texture2D t = LoadTexture(path);
    if (!t.id) return 0;
    int64_t id = chasm_rl_new(CHASM_RL_TEXTURE);
    chasm_rl_handles[id].data.texture = t;
    return id;
}
static inline void rl_unload_texture(int64_t h) {
    if (h <= 0 || h >= CHASM_RL_MAX_HANDLES) return;
    UnloadTexture(chasm_rl_handles[h].data.texture);
    chasm_rl_handles[h].kind = CHASM_RL_NONE;
}
static inline void rl_draw_texture(int64_t h, double x, double y, int64_t tint) {
    if (h <= 0 || h >= CHASM_RL_MAX_HANDLES) return;
    DrawTexture(chasm_rl_handles[h].data.texture, (int)x, (int)y, CHASM_TO_RL_COLOR(tint));
}
static inline void rl_draw_texture_ex(int64_t h, double x, double y, double rot, double scale, int64_t tint) {
    if (h <= 0 || h >= CHASM_RL_MAX_HANDLES) return;
    DrawTextureEx(chasm_rl_handles[h].data.texture,
        (Vector2){(float)x,(float)y}, (float)rot, (float)scale, CHASM_TO_RL_COLOR(tint));
}
static inline void rl_draw_texture_rec(int64_t h, double sx, double sy, double sw, double sh,
                                        double dx, double dy, int64_t tint) {
    if (h <= 0 || h >= CHASM_RL_MAX_HANDLES) return;
    DrawTextureRec(chasm_rl_handles[h].data.texture,
        (Rectangle){(float)sx,(float)sy,(float)sw,(float)sh},
        (Vector2){(float)dx,(float)dy}, CHASM_TO_RL_COLOR(tint));
}
static inline int64_t rl_texture_width(int64_t h)
    { return (h > 0 && h < CHASM_RL_MAX_HANDLES) ? chasm_rl_handles[h].data.texture.width : 0; }
static inline int64_t rl_texture_height(int64_t h)
    { return (h > 0 && h < CHASM_RL_MAX_HANDLES) ? chasm_rl_handles[h].data.texture.height : 0; }

/* ---- Font ------------------------------------------------------------------ */
static inline int64_t rl_load_font(const char *path) {
    Font f = LoadFont(path);
    int64_t id = chasm_rl_new(CHASM_RL_FONT);
    chasm_rl_handles[id].data.font = f;
    return id;
}
static inline void rl_draw_text_ex(int64_t h, const char *text,
                                    double x, double y, double size, double spacing, int64_t c) {
    if (h <= 0 || h >= CHASM_RL_MAX_HANDLES) return;
    DrawTextEx(chasm_rl_handles[h].data.font, text,
        (Vector2){(float)x,(float)y}, (float)size, (float)spacing, CHASM_TO_RL_COLOR(c));
}

/* ---- Audio ----------------------------------------------------------------- */
static inline void    rl_init_audio(void)            { InitAudioDevice(); }
static inline void    rl_close_audio(void)           { CloseAudioDevice(); }
static inline int64_t rl_load_sound(const char *p)  {
    Sound s = LoadSound(p);
    int64_t id = chasm_rl_new(CHASM_RL_SOUND);
    chasm_rl_handles[id].data.sound = s;
    return id;
}
static inline void rl_play_sound(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) PlaySound(chasm_rl_handles[h].data.sound); }
static inline void rl_stop_sound(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) StopSound(chasm_rl_handles[h].data.sound); }
static inline int64_t rl_load_music(const char *p) {
    Music m = LoadMusicStream(p);
    int64_t id = chasm_rl_new(CHASM_RL_MUSIC);
    chasm_rl_handles[id].data.music = m;
    return id;
}
static inline void rl_play_music(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) PlayMusicStream(chasm_rl_handles[h].data.music); }
static inline void rl_update_music(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) UpdateMusicStream(chasm_rl_handles[h].data.music); }
static inline void rl_stop_music(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) StopMusicStream(chasm_rl_handles[h].data.music); }

/* ---- Keyboard --------------------------------------------------------------
   Use raylib KeyboardKey int values directly: KEY_A=65, KEY_SPACE=32,
   KEY_ESCAPE=256, KEY_ENTER=257, KEY_RIGHT=262, KEY_LEFT=263,
   KEY_DOWN=264, KEY_UP=265, KEY_LEFT_SHIFT=340, KEY_LEFT_CONTROL=341 */
static inline bool    rl_is_key_pressed(int64_t k)   { return IsKeyPressed((int)k); }
static inline bool    rl_is_key_down(int64_t k)       { return IsKeyDown((int)k); }
static inline bool    rl_is_key_released(int64_t k)   { return IsKeyReleased((int)k); }
static inline bool    rl_is_key_up(int64_t k)          { return IsKeyUp((int)k); }
static inline int64_t rl_get_key_pressed(void)         { return (int64_t)GetKeyPressed(); }

static inline int64_t rl_key_from_name(const char *name) {
    if (!name) return 0;
    /* Arrow keys */
    if (strcmp(name, "right") == 0)       return KEY_RIGHT;
    if (strcmp(name, "left") == 0)        return KEY_LEFT;
    if (strcmp(name, "up") == 0)          return KEY_UP;
    if (strcmp(name, "down") == 0)        return KEY_DOWN;
    /* Common keys */
    if (strcmp(name, "space") == 0)       return KEY_SPACE;
    if (strcmp(name, "enter") == 0)       return KEY_ENTER;
    if (strcmp(name, "escape") == 0)      return KEY_ESCAPE;
    if (strcmp(name, "backspace") == 0)   return KEY_BACKSPACE;
    if (strcmp(name, "tab") == 0)         return KEY_TAB;
    /* Modifiers */
    if (strcmp(name, "shift") == 0)       return KEY_LEFT_SHIFT;
    if (strcmp(name, "left_shift") == 0)  return KEY_LEFT_SHIFT;
    if (strcmp(name, "right_shift") == 0) return KEY_RIGHT_SHIFT;
    if (strcmp(name, "ctrl") == 0)        return KEY_LEFT_CONTROL;
    if (strcmp(name, "left_ctrl") == 0)   return KEY_LEFT_CONTROL;
    if (strcmp(name, "right_ctrl") == 0)  return KEY_RIGHT_CONTROL;
    if (strcmp(name, "alt") == 0)         return KEY_LEFT_ALT;
    if (strcmp(name, "left_alt") == 0)    return KEY_LEFT_ALT;
    if (strcmp(name, "right_alt") == 0)   return KEY_RIGHT_ALT;
    /* Single letters a-z */
    if (name[0] >= 'a' && name[0] <= 'z' && name[1] == '\0') return (int64_t)(name[0] - 'a' + KEY_A);
    if (name[0] >= 'A' && name[0] <= 'Z' && name[1] == '\0') return (int64_t)(name[0] - 'A' + KEY_A);
    /* Digits 0-9 */
    if (name[0] >= '0' && name[0] <= '9' && name[1] == '\0') return (int64_t)(name[0] - '0' + KEY_ZERO);
    /* Function keys f1-f12 */
    if (name[0] == 'f' || name[0] == 'F') {
        int n = 0;
        const char *p = name + 1;
        while (*p >= '0' && *p <= '9') n = n * 10 + (*p++ - '0');
        if (*p == '\0' && n >= 1 && n <= 12) return (int64_t)(KEY_F1 + n - 1);
    }
    return 0;
}

/* ---- Mouse -----------------------------------------------------------------
   Mouse buttons: MOUSE_BUTTON_LEFT=0, MOUSE_BUTTON_RIGHT=1, MIDDLE=2        */
static inline double rl_mouse_x(void)               { return (double)GetMouseX(); }
static inline double rl_mouse_y(void)               { return (double)GetMouseY(); }
static inline double rl_mouse_delta_x(void)         { return (double)GetMouseDelta().x; }
static inline double rl_mouse_delta_y(void)         { return (double)GetMouseDelta().y; }
static inline bool   rl_is_mouse_pressed(int64_t b) { return IsMouseButtonPressed((int)b); }
static inline bool   rl_is_mouse_down(int64_t b)    { return IsMouseButtonDown((int)b); }
static inline bool   rl_is_mouse_released(int64_t b){ return IsMouseButtonReleased((int)b); }
static inline double rl_mouse_wheel(void)           { return (double)GetMouseWheelMove(); }
static inline void   rl_hide_cursor(void)           { HideCursor(); }
static inline void   rl_show_cursor(void)           { ShowCursor(); }

/* ---- Audio extended ------------------------------------------------------- */
static inline bool   rl_sound_playing(int64_t h)
    { return (h > 0 && h < CHASM_RL_MAX_HANDLES) ? IsSoundPlaying(chasm_rl_handles[h].data.sound) : false; }
static inline void   rl_sound_volume(int64_t h, double vol)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) SetSoundVolume(chasm_rl_handles[h].data.sound, (float)vol); }
static inline void   rl_sound_pitch(int64_t h, double pitch)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) SetSoundPitch(chasm_rl_handles[h].data.sound, (float)pitch); }
static inline void   rl_pause_sound(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) PauseSound(chasm_rl_handles[h].data.sound); }
static inline void   rl_resume_sound(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) ResumeSound(chasm_rl_handles[h].data.sound); }
static inline bool   rl_music_playing(int64_t h)
    { return (h > 0 && h < CHASM_RL_MAX_HANDLES) ? IsMusicStreamPlaying(chasm_rl_handles[h].data.music) : false; }
static inline void   rl_music_volume(int64_t h, double vol)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) SetMusicVolume(chasm_rl_handles[h].data.music, (float)vol); }
static inline void   rl_music_pitch(int64_t h, double pitch)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) SetMusicPitch(chasm_rl_handles[h].data.music, (float)pitch); }
static inline double rl_music_length(int64_t h)
    { return (h > 0 && h < CHASM_RL_MAX_HANDLES) ? (double)GetMusicTimeLength(chasm_rl_handles[h].data.music) : 0.0; }
static inline double rl_music_played(int64_t h)
    { return (h > 0 && h < CHASM_RL_MAX_HANDLES) ? (double)GetMusicTimePlayed(chasm_rl_handles[h].data.music) : 0.0; }
static inline void   rl_pause_music(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) PauseMusicStream(chasm_rl_handles[h].data.music); }
static inline void   rl_resume_music(int64_t h)
    { if (h > 0 && h < CHASM_RL_MAX_HANDLES) ResumeMusicStream(chasm_rl_handles[h].data.music); }

/* ---- Window extended ------------------------------------------------------- */
static inline bool  rl_window_resized(void)           { return IsWindowResized(); }
static inline void  rl_set_window_size(int64_t w, int64_t h) { SetWindowSize((int)w, (int)h); }
static inline void  rl_toggle_fullscreen(void)        { ToggleFullscreen(); }
static inline bool  rl_is_fullscreen(void)            { return IsWindowFullscreen(); }
static inline bool  rl_window_focused(void)           { return IsWindowFocused(); }

/* ---- Drawing extended ------------------------------------------------------ */
static inline void rl_draw_triangle(double x1, double y1, double x2, double y2, double x3, double y3, int64_t c)
    { DrawTriangle((Vector2){(float)x1,(float)y1}, (Vector2){(float)x2,(float)y2}, (Vector2){(float)x3,(float)y3}, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_triangle_lines(double x1, double y1, double x2, double y2, double x3, double y3, int64_t c)
    { DrawTriangleLines((Vector2){(float)x1,(float)y1}, (Vector2){(float)x2,(float)y2}, (Vector2){(float)x3,(float)y3}, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_ellipse(double cx, double cy, double rx, double ry, int64_t c)
    { DrawEllipse((int)cx, (int)cy, (float)rx, (float)ry, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_ring(double cx, double cy, double inner, double outer, double start, double end, int64_t segs, int64_t c)
    { DrawRing((Vector2){(float)cx,(float)cy}, (float)inner, (float)outer, (float)start, (float)end, (int)segs, CHASM_TO_RL_COLOR(c)); }
static inline void rl_draw_poly(double cx, double cy, int64_t sides, double radius, double rot, int64_t c)
    { DrawPoly((Vector2){(float)cx,(float)cy}, (int)sides, (float)radius, (float)rot, CHASM_TO_RL_COLOR(c)); }

/* ---- Texture extended ------------------------------------------------------ */
static inline void rl_draw_texture_tiled(int64_t h, double sx, double sy, double sw, double sh,
                                          double dx, double dy, double dw, double dh, int64_t tint) {
    if (h <= 0 || h >= CHASM_RL_MAX_HANDLES) return;
    DrawTexturePro(chasm_rl_handles[h].data.texture,
        (Rectangle){(float)sx,(float)sy,(float)sw,(float)sh},
        (Rectangle){(float)dx,(float)dy,(float)dw,(float)dh},
        (Vector2){0,0}, 0.0f, CHASM_TO_RL_COLOR(tint));
}
static inline void rl_set_texture_filter(int64_t h, int64_t filter) {
    if (h <= 0 || h >= CHASM_RL_MAX_HANDLES) return;
    SetTextureFilter(chasm_rl_handles[h].data.texture, (int)filter);
}

/* ---- Camera 2D ------------------------------------------------------------- */
static inline void rl_camera2d_begin(double cx, double cy, double tx, double ty, double rot, double zoom) {
    Camera2D cam = {{(float)cx,(float)cy},{(float)tx,(float)ty},(float)rot,(float)zoom};
    BeginMode2D(cam);
}
static inline void   rl_camera2d_end(void) { EndMode2D(); }
static inline double rl_world_to_screen_x(double wx, double wy, double cx, double cy, double tx, double ty, double rot, double zoom) {
    Camera2D cam = {{(float)cx,(float)cy},{(float)tx,(float)ty},(float)rot,(float)zoom};
    return (double)GetWorldToScreen2D((Vector2){(float)wx,(float)wy}, cam).x;
}
static inline double rl_world_to_screen_y(double wx, double wy, double cx, double cy, double tx, double ty, double rot, double zoom) {
    Camera2D cam = {{(float)cx,(float)cy},{(float)tx,(float)ty},(float)rot,(float)zoom};
    return (double)GetWorldToScreen2D((Vector2){(float)wx,(float)wy}, cam).y;
}

/* ---- Gamepad --------------------------------------------------------------- */
static inline bool   rl_gamepad_available(int64_t pad)               { return IsGamepadAvailable((int)pad); }
static inline bool   rl_gamepad_button_down(int64_t pad, int64_t btn){ return IsGamepadButtonDown((int)pad, (int)btn); }
static inline bool   rl_gamepad_button_pressed(int64_t pad, int64_t btn){ return IsGamepadButtonPressed((int)pad, (int)btn); }
static inline double rl_gamepad_axis(int64_t pad, int64_t axis)      { return (double)GetGamepadAxisMovement((int)pad, (int)axis); }

/* ---- Mouse extended -------------------------------------------------------- */
static inline void rl_set_mouse_pos(double x, double y)  { SetMousePosition((int)x, (int)y); }
static inline void rl_mouse_cursor(int64_t cursor)       { SetMouseCursor((int)cursor); }

/* ---- Clipboard ------------------------------------------------------------- */
static inline const char *rl_get_clipboard(void) {
    const char *s = GetClipboardText();
    return s ? s : "";
}
static inline void rl_set_clipboard(const char *text) { SetClipboardText(text); }

/* ---- Collision ------------------------------------------------------------- */
static inline bool rl_check_collision_recs(double x1, double y1, double w1, double h1,
                                            double x2, double y2, double w2, double h2) {
    return CheckCollisionRecs(
        (Rectangle){(float)x1,(float)y1,(float)w1,(float)h1},
        (Rectangle){(float)x2,(float)y2,(float)w2,(float)h2});
}
static inline bool rl_check_collision_circles(double x1, double y1, double r1,
                                               double x2, double y2, double r2) {
    return CheckCollisionCircles(
        (Vector2){(float)x1,(float)y1}, (float)r1,
        (Vector2){(float)x2,(float)y2}, (float)r2);
}
static inline bool rl_check_collision_point_rec(double px, double py,
                                                 double rx, double ry, double rw, double rh) {
    return CheckCollisionPointRec(
        (Vector2){(float)px,(float)py},
        (Rectangle){(float)rx,(float)ry,(float)rw,(float)rh});
}

/* rand_range: float in [lo, hi) */
static inline double rl_rand_range(double lo, double hi) {
    return lo + (hi - lo) * ((double)GetRandomValue(0, 32767) / 32767.0);
}
