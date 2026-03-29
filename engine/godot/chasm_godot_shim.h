#pragma once
/* chasm_godot_shim.h — Godot API shim for compiled Chasm scripts.
 *
 * Include via -include in the cc invocation when compiling a Chasm script for
 * the Godot engine (the same role chasm_rl_shim.h plays for Raylib). Maps the
 * extern fn declarations in godot.chasm to C functions exported by the GDE
 * plugin. The linker resolves them from the already-loaded chasm_gde.so.
 */

#include "../raylib/chasm_rt.h"
#include <stdint.h>
#include <stdbool.h>

/* Position — Node2D and subclasses. */
extern double  gdot_get_pos_x(void);
extern double  gdot_get_pos_y(void);
extern void    gdot_set_position(double x, double y);

/* Physics — CharacterBody2D. */
extern void    gdot_move_and_slide(void);
extern void    gdot_set_velocity(double vx, double vy);
extern double  gdot_get_vel_x(void);
extern double  gdot_get_vel_y(void);

/* Signals. */
extern void    gdot_emit_signal(const char *signal_name);

/* Scene tree — returns opaque handle as int64. */
extern int64_t gdot_get_node(const char *path);

/* Audio. */
extern void    gdot_play_audio(const char *path);

/* Input. */
extern bool    gdot_is_action_pressed(const char *action);
extern bool    gdot_is_action_just_pressed(const char *action);
extern bool    gdot_is_action_just_released(const char *action);
extern double  gdot_get_axis(const char *neg_action, const char *pos_action);

/* Logging — pipes to Godot editor Output panel. */
extern void    gdot_print(const char *msg);
extern void    gdot_print_err(const char *msg);
