const std      = @import("std");
const builtin  = @import("builtin");
const ArenaTriple = @import("runtime").ArenaTriple;
const Lexer    = @import("lexer").Lexer;
const Parser   = @import("parser").Parser;
const AstPool  = @import("ast").AstPool;
const DiagList = @import("diag").DiagList;
const Sema     = @import("sema").Sema;
const Lowerer  = @import("lower").Lowerer;
const codegen      = @import("codegen");
const codegen_wasm = @import("codegen_wasm");
const reload   = @import("reload");
const ir_mod   = @import("ir");

const raylib_prelude = @import("prelude").raylib_prelude;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const args = try std.process.argsAlloc(backing);
    defer std.process.argsFree(backing, args);

    if (args.len < 2) {
        try usage();
        std.process.exit(1);
    }

    // ---- Sub-command dispatch ----------------------------------------------
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "version")) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("chasm 0.1.0\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "--watch") or std.mem.eql(u8, args[1], "watch")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm --watch <file.chasm>\n", .{});
            std.process.exit(1);
        }
        try watchMode(args[2], backing);
        return;
    }

    if (std.mem.eql(u8, args[1], "run")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm run <file.chasm> [--link libname ...] [--engine raylib]\n", .{});
            std.process.exit(1);
        }
        // Collect --link flags and --engine flag
        var link_libs = std.ArrayListUnmanaged([]const u8){};
        defer link_libs.deinit(backing);
        var file_path_run: []const u8 = "";
        var engine_raylib = false;
        var watch_mode    = false;
        var j: usize = 2;
        while (j < args.len) : (j += 1) {
            if (std.mem.eql(u8, args[j], "--link") and j + 1 < args.len) {
                j += 1;
                try link_libs.append(backing, args[j]);
            } else if (std.mem.eql(u8, args[j], "--engine") and j + 1 < args.len) {
                j += 1;
                if (std.mem.eql(u8, args[j], "raylib")) engine_raylib = true;
            } else if (std.mem.eql(u8, args[j], "--watch")) {
                watch_mode = true;
            } else {
                file_path_run = args[j];
            }
        }
        try runModeWithLinks(file_path_run, link_libs.items, engine_raylib, watch_mode, backing);
        return;
    }

    if (std.mem.eql(u8, args[1], "compile")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm compile <file.chasm> [--link libname ...]\n", .{});
            std.process.exit(1);
        }
        var link_libs_compile = std.ArrayListUnmanaged([]const u8){};
        defer link_libs_compile.deinit(backing);
        var compile_path: []const u8 = "";
        var compile_engine_raylib = false;
        var ci: usize = 2;
        while (ci < args.len) : (ci += 1) {
            if (std.mem.eql(u8, args[ci], "--link") and ci + 1 < args.len) {
                ci += 1;
                try link_libs_compile.append(backing, args[ci]);
            } else if (std.mem.eql(u8, args[ci], "--engine") and ci + 1 < args.len) {
                ci += 1;
                if (std.mem.eql(u8, args[ci], "raylib")) compile_engine_raylib = true;
            } else {
                compile_path = args[ci];
            }
        }
        var compile_arenas = ArenaTriple.init(backing);
        defer compile_arenas.deinit();
        const compile_frame = compile_arenas.allocator(.frame);
        if (compile_path.len == 0) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm compile <file.chasm> [--engine raylib] [--link lib]\n", .{});
            std.process.exit(1);
        }
        const compile_prelude: ?[]const u8 = if (compile_engine_raylib) raylib_prelude else null;
        const compile_module = try compileFileOpts(compile_path, compile_frame, true, null, compile_prelude) orelse std.process.exit(1);
        try writeOutputOpts(compile_path, compile_module, compile_engine_raylib, compile_frame);
        if (link_libs_compile.items.len > 0) {
            const stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.print("  link flags:", .{});
            for (link_libs_compile.items) |lib| try stdout.print(" -l{s}", .{lib});
            try stdout.print("\n", .{});
        }
        return;
    }

    if (std.mem.eql(u8, args[1], "compare")) {
        if (args.len < 4) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm compare <old.chasm> <new.chasm>\n", .{});
            std.process.exit(1);
        }
        try compareMode(args[2], args[3], backing);
        return;
    }

    // ---- Default: single compile -------------------------------------------
    var arenas = ArenaTriple.init(backing);
    defer arenas.deinit();
    const frame_alloc = arenas.allocator(.frame);

    // Check for --target wasm flag
    var wasm_target = false;
    var path: []const u8 = args[1];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "wasm")) {
                wasm_target = true;
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            path = args[i];
        }
    }

    const ir_module = try compileFile(path, frame_alloc) orelse std.process.exit(1);
    if (wasm_target) {
        try writeWasmOutput(path, ir_module, frame_alloc);
    } else {
        try writeOutput(path, ir_module, frame_alloc);
    }
    arenas.clearFrame();
}

// ---------------------------------------------------------------------------
// Compare two files and print the reload diff
// ---------------------------------------------------------------------------

fn compareMode(old_path: []const u8, new_path: []const u8, backing: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var old_arenas = ArenaTriple.init(backing);
    defer old_arenas.deinit();
    var new_arenas = ArenaTriple.init(backing);
    defer new_arenas.deinit();

    const old_module = try compileFile(old_path, old_arenas.allocator(.frame)) orelse {
        try stderr.print("compare: failed to compile {s}\n", .{old_path});
        std.process.exit(1);
    };
    const new_module = try compileFile(new_path, new_arenas.allocator(.frame)) orelse {
        try stderr.print("compare: failed to compile {s}\n", .{new_path});
        std.process.exit(1);
    };

    try stdout.print("Reload analysis: {s} → {s}\n\n", .{ old_path, new_path });
    var diff_arena = std.heap.ArenaAllocator.init(backing);
    defer diff_arena.deinit();
    const report = try reload.diff(old_module, new_module, diff_arena.allocator());
    try reload.renderReport(report, stdout);
}

// ---------------------------------------------------------------------------
// Watch mode — poll for file changes, recompile, show reload diff
// ---------------------------------------------------------------------------

fn watchMode(path: []const u8, backing: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    try stdout.print("[watch] {s}\n", .{path});

    // Snapshot of attrs from the last successful compile (null on first run).
    var prev_snap: ?reload.ModuleSnapshot = null;
    defer if (prev_snap) |*s| s.deinit(backing);

    var last_mtime: i128 = 0;

    while (true) {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            try stderr.print("[watch] stat error: {s}\n", .{@errorName(err)});
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        };

        if (stat.mtime != last_mtime) {
            last_mtime = stat.mtime;
            if (last_mtime != 0) {
                try stdout.print("\n[watch] {s} changed — recompiling...\n", .{path});
            }

            var arenas = ArenaTriple.init(backing);
            const frame_alloc = arenas.allocator(.frame);

            if (try compileFile(path, frame_alloc)) |new_module| {
                // Show reload diff if we have a previous version.
                if (prev_snap) |*old_snap| {
                    const old_ir = try old_snap.toIrModule(frame_alloc);
                    const report = try reload.diff(old_ir, new_module, frame_alloc);
                    try stdout.print("Reload analysis:\n", .{});
                    try reload.renderReport(report, stdout);
                }

                // Capture snapshot before clearing frame arena.
                const new_snap = try reload.ModuleSnapshot.capture(new_module, backing);
                if (prev_snap) |*s| s.deinit(backing);
                prev_snap = new_snap;

                try writeOutput(path, new_module, frame_alloc);
            }

            arenas.deinit();
        }

        std.Thread.sleep(300 * std.time.ns_per_ms);
    }
}

// ---------------------------------------------------------------------------
// Shared compilation pipeline
// ---------------------------------------------------------------------------

/// Compile `path` and return the `IrModule`, or print errors and return null.
/// All allocations use `frame_alloc` (caller is responsible for the arena).
/// Pass `verbose = false` to suppress the summary line (e.g. for `chasm run`).
fn compileFile(path: []const u8, frame_alloc: std.mem.Allocator) !?ir_mod.IrModule {
    return compileFileOpts(path, frame_alloc, true, null, null);
}

fn compileFileOpts(path: []const u8, frame_alloc: std.mem.Allocator, verbose: bool, imported_out: ?*std.ArrayListUnmanaged([]const u8), prelude: ?[]const u8) !?ir_mod.IrModule {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const file_src = std.fs.cwd().readFileAlloc(frame_alloc, path, 4 * 1024 * 1024) catch |err| {
        try stderr.print("{s}: read error: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    const src = if (prelude) |p|
        try std.mem.concat(frame_alloc, u8, &.{ p, "\n", file_src })
    else
        file_src;

    var pool  = AstPool.init(frame_alloc);
    var diags = DiagList.initWithSource(frame_alloc, src);

    var lexer = Lexer.init(src);
    const tokens = lexer.tokenize(frame_alloc) catch |err| {
        try stderr.print("{s}: lex error: {s}\n", .{ path, @errorName(err) });
        return null;
    };

    var parser = Parser.init(tokens, &pool, &diags, frame_alloc);
    const top_level = parser.parseFile() catch |err| {
        try diags.render(path, stderr);
        try stderr.print("{s}: parse error: {s}\n", .{ path, @errorName(err) });
        return null;
    };

    if (diags.hasErrors()) {
        try diags.render(path, stderr);
        return null;
    }

    var sema = Sema.initWithFile(&pool, &diags, frame_alloc, path);
    try sema.analyze(top_level);

    // Collect imported file paths if the caller wants them.
    if (imported_out) |out| {
        for (sema.imported_files.items) |imp| {
            try out.append(frame_alloc, imp);
        }
    }

    if (diags.hasErrors()) {
        try diags.render(path, stderr);
        return null;
    }

    var lowerer = Lowerer.init(&pool, &sema, frame_alloc);
    const ir_module = try lowerer.lower(top_level);

    if (verbose) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const s = sema.stats;
        try stdout.print("{s}: {d} decls, {d} symbols — frame:{d} script:{d} persistent:{d}\n",
            .{ path, top_level.len, s.symbols_resolved, s.frame_vars, s.script_vars, s.persistent_vars });
    }

    return ir_module;
}

/// Write WAT output for a compiled module (WASM target).
fn writeWasmOutput(path: []const u8, ir_module: ir_mod.IrModule, frame_alloc: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const out_path = blk: {
        if (std.mem.endsWith(u8, path, ".chasm")) {
            const base = path[0 .. path.len - ".chasm".len];
            break :blk try std.fmt.allocPrint(frame_alloc, "{s}.wat", .{base});
        }
        break :blk try std.fmt.allocPrint(frame_alloc, "{s}.wat", .{path});
    };

    const wat_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        try stderr.print("{s}: write error: {s}\n", .{ out_path, @errorName(err) });
        return;
    };
    defer wat_file.close();
    try codegen_wasm.emitWat(ir_module, wat_file.deprecatedWriter());

    try stdout.print("  output → {s}\n", .{out_path});

    // Also emit an index.html browser host alongside the .wat.
    const html_path = blk: {
        if (std.mem.endsWith(u8, out_path, ".wat")) {
            const base = out_path[0 .. out_path.len - ".wat".len];
            break :blk try std.fmt.allocPrint(frame_alloc, "{s}.html", .{base});
        }
        break :blk try std.fmt.allocPrint(frame_alloc, "{s}.html", .{out_path});
    };
    const wasm_name = blk: {
        const bn = std.fs.path.basename(out_path);
        if (std.mem.endsWith(u8, bn, ".wat")) {
            break :blk try std.fmt.allocPrint(frame_alloc, "{s}.wasm", .{bn[0 .. bn.len - ".wat".len]});
        }
        break :blk try std.fmt.allocPrint(frame_alloc, "{s}.wasm", .{bn});
    };
    const html_file = std.fs.cwd().createFile(html_path, .{}) catch null;
    if (html_file) |hf| {
        defer hf.close();
        try emitWasmHost(ir_module, wasm_name, hf.deprecatedWriter());
        try stdout.print("  output → {s}  (compile .wat with: wat2wasm {s})\n", .{ html_path, out_path });
    }
}

/// Emit a browser host HTML file for the compiled WASM module.
/// Loads `wasm_name` (the compiled .wasm file) and provides Canvas2D env imports.
fn emitWasmHost(module: ir_mod.IrModule, wasm_name: []const u8, writer: anytype) !void {
    // Detect which hooks exist.
    var has_on_init = false;
    var has_on_tick = false;
    var has_on_draw = false;
    for (module.functions) |f| {
        if (std.mem.eql(u8, f.name, "on_init")) has_on_init = true;
        if (std.mem.eql(u8, f.name, "on_tick")) has_on_tick = true;
        if (std.mem.eql(u8, f.name, "on_draw")) has_on_draw = true;
    }

    try writer.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <title>Chasm WASM</title>
        \\  <style>
        \\    body {{ background:#111; display:flex; justify-content:center; align-items:center; height:100vh; margin:0; }}
        \\    canvas {{ border:1px solid #333; }}
        \\  </style>
        \\</head>
        \\<body>
        \\<canvas id="c" width="800" height="600"></canvas>
        \\<script>
        \\(async () => {{
        \\  const canvas = document.getElementById('c');
        \\  const ctx    = canvas.getContext('2d');
        \\
        \\  function colorCss(packed) {{
        \\    const r = (packed >>> 24) & 0xFF;
        \\    const g = (packed >>> 16) & 0xFF;
        \\    const b = (packed >>>  8) & 0xFF;
        \\    const a = (packed & 0xFF) / 255;
        \\    return `rgba(${{r}},${{g}},${{b}},${{a}})`;
        \\  }}
        \\
        \\  const env = {{
        \\    // I/O
        \\    print: (v) => console.log(Number(v)),
        \\    // Math
        \\    abs:   (v) => Math.abs(v),
        \\    sqrt:  (v) => Math.sqrt(v),
        \\    sin:   (v) => Math.sin(v),
        \\    cos:   (v) => Math.cos(v),
        \\    floor: (v) => Math.floor(v),
        \\    ceil:  (v) => Math.ceil(v),
        \\    round: (v) => Math.round(v),
        \\    min:   (a, b) => Math.min(a, b),
        \\    max:   (a, b) => Math.max(a, b),
        \\    clamp: (v, lo, hi) => Math.min(Math.max(v, lo), hi),
        \\    lerp:  (a, b, t) => a + (b - a) * t,
        \\    atan2: (y, x) => Math.atan2(y, x),
        \\    // Drawing
        \\    clear: (color) => {{
        \\      ctx.fillStyle = colorCss(color >>> 0);
        \\      ctx.fillRect(0, 0, canvas.width, canvas.height);
        \\    }},
        \\    draw_rect: (x, y, w, h, color) => {{
        \\      ctx.fillStyle = colorCss(color >>> 0);
        \\      ctx.fillRect(x, y, w, h);
        \\    }},
        \\    draw_circle: (x, y, r, color) => {{
        \\      ctx.fillStyle = colorCss(color >>> 0);
        \\      ctx.beginPath(); ctx.arc(x, y, r, 0, 2*Math.PI); ctx.fill();
        \\    }},
        \\    draw_circle_lines: (x, y, r, color) => {{
        \\      ctx.strokeStyle = colorCss(color >>> 0);
        \\      ctx.beginPath(); ctx.arc(x, y, r, 0, 2*Math.PI); ctx.stroke();
        \\    }},
        \\    draw_line: (x1, y1, x2, y2, color) => {{
        \\      ctx.strokeStyle = colorCss(color >>> 0);
        \\      ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
        \\    }},
        \\    draw_rect_lines: (x, y, w, h, color) => {{
        \\      ctx.strokeStyle = colorCss(color >>> 0);
        \\      ctx.strokeRect(x, y, w, h);
        \\    }},
        \\    draw_text: (ptr, x, y, size, color) => {{
        \\      ctx.fillStyle = colorCss(color >>> 0);
        \\      ctx.font = `${{size}}px monospace`;
        \\      ctx.fillText('(text)', x, y + size);
        \\    }},
        \\    draw_fps: (_x, _y) => {{}},
        \\    measure_text: (_ptr, _size) => 60,
        \\    // Input (stub — always false/zero)
        \\    key_down: (_k) => 0, key_pressed: (_k) => 0,
        \\    key_released: (_k) => 0, key_up: (_k) => 1, key_last: () => 0,
        \\    mouse_x: () => 0, mouse_y: () => 0,
        \\    mouse_dx: () => 0, mouse_dy: () => 0,
        \\    mouse_down: (_b) => 0, mouse_pressed: (_b) => 0,
        \\    mouse_released: (_b) => 0, mouse_wheel: () => 0,
        \\    hide_cursor: () => {{}}, show_cursor: () => {{}},
        \\    // Window
        \\    screen_w: () => canvas.width, screen_h: () => canvas.height,
        \\    set_fps: (_n) => {{}}, set_title: (_p) => {{}},
        \\    fps: () => 60, dt: () => 0.016, time: () => performance.now() / 1000,
        \\    // Collision (stubs)
        \\    collide_rects: () => 0, collide_circles: () => 0, point_in_rect: () => 0,
        \\  }};
        \\
        \\  const {{ instance }} = await WebAssembly.instantiateStreaming(fetch('{s}'), {{ env }});
        \\  const ex = instance.exports;
        \\
        , .{wasm_name});

    if (has_on_init) {
        try writer.print("  if (ex.on_init) ex.on_init();\n", .{});
    }

    try writer.print(
        \\  let prev = 0;
        \\  function loop(ts) {{
        \\    const dt = prev ? (ts - prev) / 1000 : 0.016;
        \\    prev = ts;
        \\
        , .{});

    if (has_on_tick) try writer.print("    if (ex.on_tick) ex.on_tick(dt);\n", .{});
    if (has_on_draw) try writer.print("    if (ex.on_draw) ex.on_draw();\n", .{});

    try writer.print(
        \\    requestAnimationFrame(loop);
        \\  }}
        \\  requestAnimationFrame(loop);
        \\}})();
        \\</script>
        \\</body>
        \\</html>
        \\
        , .{});
}

/// Write C output and runtime header for a compiled module.
fn writeOutput(path: []const u8, ir_module: ir_mod.IrModule, frame_alloc: std.mem.Allocator) !void {
    try writeOutputOpts(path, ir_module, false, frame_alloc);
}

fn writeOutputOpts(path: []const u8, ir_module: ir_mod.IrModule, engine_raylib: bool, frame_alloc: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const out_path = blk: {
        if (std.mem.endsWith(u8, path, ".chasm")) {
            const base = path[0 .. path.len - ".chasm".len];
            break :blk try std.fmt.allocPrint(frame_alloc, "{s}.c", .{base});
        }
        break :blk try std.fmt.allocPrint(frame_alloc, "{s}.c", .{path});
    };

    const c_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        try stderr.print("{s}: write error: {s}\n", .{ out_path, @errorName(err) });
        return;
    };
    defer c_file.close();
    if (engine_raylib) {
        try codegen.emitModuleRaylib(ir_module, c_file.deprecatedWriter());
    } else {
        try codegen.emitModule(ir_module, c_file.deprecatedWriter());
    }

    // Write runtime header alongside source if not already present.
    const dir     = std.fs.path.dirname(out_path) orelse ".";
    const rt_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rt.h", .{dir});
    const rt_file = std.fs.cwd().createFile(rt_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (rt_file) |f| {
        defer f.close();
        try codegen.emitRuntimeHeader(f.deprecatedWriter());
    }

    try stdout.print("  output → {s}\n", .{out_path});
}

// ---------------------------------------------------------------------------
// Hot-reload run mode — compile to dylib, dlopen harness, watch for changes
// ---------------------------------------------------------------------------

/// Build the cc argument list for compiling script.c to a dylib or binary.
/// `output_path` is the `-o` target; `is_dylib` adds `-dynamiclib`.
fn buildCcArgs(
    output_path: []const u8,
    script_c:    []const u8,
    harness_c:   ?[]const u8,   // null for dylib builds
    tmp_dir:     []const u8,
    raylib_dir:  []const u8,
    is_dylib:    bool,
    list:        *std.ArrayListUnmanaged([]const u8),
    backing:     std.mem.Allocator,
    frame_alloc: std.mem.Allocator,
) !void {
    try list.appendSlice(backing, &.{ "cc", "-o", output_path });
    if (is_dylib) {
        try list.appendSlice(backing, &.{ "-dynamiclib" });
        if (builtin.os.tag == .macos) {
            try list.appendSlice(backing, &.{ "-undefined", "dynamic_lookup" });
        }
    }
    try list.append(backing, script_c);
    if (harness_c) |hc| try list.append(backing, hc);
    try list.appendSlice(backing, &.{ "-I", tmp_dir });
    const inc = try std.fmt.allocPrint(frame_alloc, "{s}/include", .{raylib_dir});
    try list.appendSlice(backing, &.{ "-I", inc });
    if (!is_dylib) {
        const static_lib = try std.fmt.allocPrint(frame_alloc, "{s}/lib/libraylib.a", .{raylib_dir});
        try list.append(backing, static_lib);
        if (builtin.os.tag == .macos) {
            try list.appendSlice(backing, &.{
                "-framework", "OpenGL",
                "-framework", "Cocoa",
                "-framework", "IOKit",
                "-framework", "CoreVideo",
                "-framework", "CoreAudio",
                "-framework", "AudioToolbox",
            });
        } else if (builtin.os.tag == .linux) {
            try list.appendSlice(backing, &.{ "-lGL", "-lm", "-lpthread", "-ldl", "-lrt", "-lX11" });
        }
    }
}

fn runRaylibHotReload(path: []const u8, link_libs: []const []const u8, backing: std.mem.Allocator) !void {
    _ = link_libs;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var arenas = ArenaTriple.init(backing);
    defer arenas.deinit();
    const frame_alloc = arenas.allocator(.frame);

    // Resolve absolute source path so embedded harness strings are stable.
    const abs_path = try std.fs.cwd().realpathAlloc(frame_alloc, path);

    // ---- Compile .chasm → C ------------------------------------------------
    const ir_module = try compileFileOpts(abs_path, frame_alloc, false, null, raylib_prelude) orelse std.process.exit(1);

    const tmp_dir = try std.fmt.allocPrint(frame_alloc, "/tmp/chasm_run_{d}", .{std.time.milliTimestamp()});
    try std.fs.cwd().makePath(tmp_dir);

    const script_c = try std.fmt.allocPrint(frame_alloc, "{s}/script.c", .{tmp_dir});
    {
        const f = try std.fs.cwd().createFile(script_c, .{});
        defer f.close();
        try codegen.emitModuleRaylib(ir_module, f.deprecatedWriter());
    }
    {
        const rt_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rt.h", .{tmp_dir});
        const rt_file = try std.fs.cwd().createFile(rt_path, .{});
        defer rt_file.close();
        try codegen.emitRuntimeHeader(rt_file.deprecatedWriter());
    }
    {
        const rl_h_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rl.h", .{tmp_dir});
        const rl_h_file = try std.fs.cwd().createFile(rl_h_path, .{});
        defer rl_h_file.close();
        try codegen.emitRaylibHeader(rl_h_file.deprecatedWriter());
    }

    // ---- Resolve raylib dir ------------------------------------------------
    const raylib_dir: []const u8 = blk: {
        std.fs.cwd().access("engine/raylib-5.5_macos", .{}) catch {
            std.fs.cwd().access("raylib-5.5_macos", .{}) catch {
                const exe_dir = std.fs.selfExeDirPathAlloc(backing) catch break :blk "engine/raylib-5.5_macos";
                defer backing.free(exe_dir);
                const alt = try std.fmt.allocPrint(frame_alloc, "{s}/../../engine/raylib-5.5_macos", .{exe_dir});
                break :blk alt;
            };
            break :blk "raylib-5.5_macos";
        };
        break :blk "engine/raylib-5.5_macos";
    };

    // ---- Compile script.c → script_0.dylib ---------------------------------
    const dylib_path = try std.fmt.allocPrint(frame_alloc, "{s}/script_0.dylib", .{tmp_dir});
    {
        var cc_args = std.ArrayListUnmanaged([]const u8){};
        defer cc_args.deinit(backing);
        try buildCcArgs(dylib_path, script_c, null, tmp_dir, raylib_dir, true, &cc_args, backing, frame_alloc);
        var proc = std.process.Child.init(cc_args.items, backing);
        proc.stderr_behavior = .Inherit;
        const term = try proc.spawnAndWait();
        if (term != .Exited or term.Exited != 0) {
            try stderr.print("chasm run: cc (dylib) failed\n", .{});
            std.process.exit(1);
        }
    }

    // ---- Resolve chasm exe path for the reload compile command -------------
    const chasm_exe = std.fs.selfExePathAlloc(backing) catch "chasm";
    defer backing.free(chasm_exe);

    // Derive the C output path: chasm compile writes {abs_base}.c next to source.
    const abs_c_out = blk: {
        if (std.mem.endsWith(u8, abs_path, ".chasm")) {
            break :blk try std.fmt.allocPrint(frame_alloc, "{s}.c", .{abs_path[0 .. abs_path.len - ".chasm".len]});
        }
        break :blk try std.fmt.allocPrint(frame_alloc, "{s}.c", .{abs_path});
    };

    // Build cc reload command template (output path has %lld for reload index).
    const raylib_inc  = try std.fmt.allocPrint(frame_alloc, "{s}/include", .{raylib_dir});
    const abs_rl_inc  = if (std.fs.path.isAbsolute(raylib_inc)) raylib_inc
        else try std.fs.cwd().realpathAlloc(frame_alloc, raylib_inc);
    var cc_reload_cmd = std.ArrayListUnmanaged(u8){};
    defer cc_reload_cmd.deinit(frame_alloc);
    try cc_reload_cmd.appendSlice(frame_alloc, "cc -dynamiclib");
    if (builtin.os.tag == .macos) {
        try cc_reload_cmd.appendSlice(frame_alloc, " -undefined dynamic_lookup");
    }
    try cc_reload_cmd.writer(frame_alloc).print(" -o {s}/script_%lld.dylib {s} -I {s} -I {s}",
        .{ tmp_dir, abs_c_out, tmp_dir, abs_rl_inc });

    // ---- Write hot-reload harness ------------------------------------------
    const harness_path = try std.fmt.allocPrint(frame_alloc, "{s}/harness.c", .{tmp_dir});
    {
        const hf = try std.fs.cwd().createFile(harness_path, .{});
        defer hf.close();
        const hw = hf.deprecatedWriter();

        var has_on_init   = false;
        var has_on_tick   = false;
        var has_on_draw   = false;
        var has_on_unload = false;
        for (ir_module.functions) |func| {
            if (std.mem.eql(u8, func.name, "on_init"))   has_on_init   = true;
            if (std.mem.eql(u8, func.name, "on_tick"))   has_on_tick   = true;
            if (std.mem.eql(u8, func.name, "on_draw"))   has_on_draw   = true;
            if (std.mem.eql(u8, func.name, "on_unload")) has_on_unload = true;
        }

        try hw.print(
            \\#include "chasm_rl.h"
            \\#include <dlfcn.h>
            \\#include <sys/stat.h>
            \\#include <stdio.h>
            \\#include <stdlib.h>
            \\#include <string.h>
            \\
            \\static const char *SOURCE_PATH    = "{s}";
            \\static const char *CHASM_EXE      = "{s}";
            \\static const char *TMP_DIR        = "{s}";
            \\static const char *CC_RELOAD_FMT  = "{s}";
            \\
            \\static void *g_lib          = NULL;
            \\static long long g_reload_idx = 0;
            \\
            \\typedef void (*ModInitFn)(ChasmCtx *);
            \\typedef void (*TickFn)(ChasmCtx *, double);
            \\typedef void (*DrawFn)(ChasmCtx *);
            \\typedef void (*VoidCtxFn)(ChasmCtx *);
            \\
            \\static ModInitFn fn_module_init = NULL;
            \\static TickFn    fn_on_tick     = NULL;
            \\static DrawFn    fn_on_draw     = NULL;
            \\static VoidCtxFn fn_on_init     = NULL;
            \\static VoidCtxFn fn_on_unload   = NULL;
            \\
            \\static int load_lib(const char *path) {{
            \\    void *nl = dlopen(path, RTLD_NOW | RTLD_LOCAL);
            \\    if (!nl) {{ fprintf(stderr, "[hot-reload] dlopen: %s\n", dlerror()); return 0; }}
            \\    if (g_lib) dlclose(g_lib);
            \\    g_lib          = nl;
            \\    fn_module_init = (ModInitFn) dlsym(nl, "chasm_module_init");
            \\    fn_on_tick     = (TickFn)    dlsym(nl, "chasm_on_tick");
            \\    fn_on_draw     = (DrawFn)    dlsym(nl, "chasm_on_draw");
            \\    fn_on_init     = (VoidCtxFn) dlsym(nl, "chasm_on_init");
            \\    fn_on_unload   = (VoidCtxFn) dlsym(nl, "chasm_on_unload");
            \\    fprintf(stderr, "[hot-reload] loaded %s\n", path);
            \\    return 1;
            \\}}
            \\
            \\static void try_reload(void) {{
            \\    g_reload_idx++;
            \\    /* Step 1: recompile .chasm → .c */
            \\    char chasm_cmd[1024];
            \\    snprintf(chasm_cmd, sizeof(chasm_cmd),
            \\        "%s compile --engine raylib %s", CHASM_EXE, SOURCE_PATH);
            \\    if (system(chasm_cmd) != 0) {{
            \\        fprintf(stderr, "[hot-reload] chasm compile failed\n");
            \\        g_reload_idx--; return;
            \\    }}
            \\    /* Step 2: compile .c → .dylib */
            \\    char cc_cmd[4096];
            \\    snprintf(cc_cmd, sizeof(cc_cmd), CC_RELOAD_FMT, g_reload_idx);
            \\    if (system(cc_cmd) != 0) {{
            \\        fprintf(stderr, "[hot-reload] cc failed\n");
            \\        g_reload_idx--; return;
            \\    }}
            \\    char dylib[512];
            \\    snprintf(dylib, sizeof(dylib), "%s/script_%lld.dylib", TMP_DIR, g_reload_idx);
            \\    if (!load_lib(dylib)) g_reload_idx--;
            \\}}
            \\
            \\int main(void) {{
            \\    static uint8_t frame_mem  [ 1*1024*1024];
            \\    static uint8_t script_mem [ 4*1024*1024];
            \\    static uint8_t persist_mem[16*1024*1024];
            \\    ChasmCtx ctx = {{
            \\        .frame      = {{frame_mem,   0, sizeof(frame_mem)}},
            \\        .script     = {{script_mem,  0, sizeof(script_mem)}},
            \\        .persistent = {{persist_mem, 0, sizeof(persist_mem)}},
            \\    }};
            \\    char init_dylib[512];
            \\    snprintf(init_dylib, sizeof(init_dylib), "%s/script_0.dylib", TMP_DIR);
            \\    if (!load_lib(init_dylib) || !fn_module_init) {{
            \\        fprintf(stderr, "chasm: failed to load module\n"); return 1;
            \\    }}
            \\    fn_module_init(&ctx);
            \\    InitWindow(800, 600, "Chasm (hot-reload)");
            \\    SetTargetFPS(60);
            \\
            , .{ abs_path, chasm_exe, tmp_dir, cc_reload_cmd.items });

        if (has_on_init) try hw.print("    fn_on_init(&ctx);\n", .{});

        try hw.print(
            \\    struct stat src_st = {{0}};
            \\    stat(SOURCE_PATH, &src_st);
            \\    long src_mtime = (long)src_st.st_mtime;
            \\    while (!WindowShouldClose()) {{
            \\        if (stat(SOURCE_PATH, &src_st) == 0 && (long)src_st.st_mtime != src_mtime) {{
            \\            src_mtime = (long)src_st.st_mtime;
            \\            try_reload();
            \\        }}
            \\        double dt = (double)GetFrameTime();
            \\
            , .{});

        if (has_on_tick) try hw.print("        fn_on_tick(&ctx, dt);\n", .{});
        try hw.print(
            \\        BeginDrawing();
            \\        ClearBackground((Color){{0,0,0,255}});
            \\
            , .{});
        if (has_on_draw) try hw.print("        fn_on_draw(&ctx);\n", .{});
        try hw.print(
            \\        EndDrawing();
            \\        chasm_clear_frame(&ctx);
            \\    }}
            \\
            , .{});
        if (has_on_unload) try hw.print("    fn_on_unload(&ctx);\n", .{});
        try hw.print(
            \\    CloseWindow();
            \\    return 0;
            \\}}
            \\
            , .{});
    }

    // ---- Compile harness → binary ------------------------------------------
    const bin_path = try std.fmt.allocPrint(frame_alloc, "{s}/out", .{tmp_dir});
    {
        var cc_args = std.ArrayListUnmanaged([]const u8){};
        defer cc_args.deinit(backing);
        try buildCcArgs(bin_path, harness_path, null, tmp_dir, raylib_dir, false, &cc_args, backing, frame_alloc);
        // Remove script.c from args (harness only)
        var clean_args = std.ArrayListUnmanaged([]const u8){};
        defer clean_args.deinit(backing);
        // Rebuild: cc -o bin harness.c -I tmp raylib.a [frameworks]
        try clean_args.appendSlice(backing, &.{ "cc", "-o", bin_path, harness_path, "-I", tmp_dir });
        const rl_inc = try std.fmt.allocPrint(frame_alloc, "{s}/include", .{raylib_dir});
        const rl_lib = try std.fmt.allocPrint(frame_alloc, "{s}/lib/libraylib.a", .{raylib_dir});
        try clean_args.appendSlice(backing, &.{ "-I", rl_inc, rl_lib });
        if (builtin.os.tag == .macos) {
            try clean_args.appendSlice(backing, &.{
                "-framework", "OpenGL", "-framework", "Cocoa",
                "-framework", "IOKit",  "-framework", "CoreVideo",
                "-framework", "CoreAudio", "-framework", "AudioToolbox",
            });
        } else if (builtin.os.tag == .linux) {
            try clean_args.appendSlice(backing, &.{ "-lGL", "-lm", "-lpthread", "-ldl", "-lrt", "-lX11" });
        }
        var proc = std.process.Child.init(clean_args.items, backing);
        proc.stderr_behavior = .Inherit;
        const term = try proc.spawnAndWait();
        if (term != .Exited or term.Exited != 0) {
            try stderr.print("chasm run: cc (harness) failed\n", .{});
            std.process.exit(1);
        }
    }

    try stdout.print("  running {s} (hot-reload)...\n\n", .{path});

    // ---- Execute -----------------------------------------------------------
    const run_argv = [_][]const u8{bin_path};
    var run_proc = std.process.Child.init(&run_argv, backing);
    run_proc.stdout_behavior = .Inherit;
    run_proc.stderr_behavior = .Inherit;
    const run_term = try run_proc.spawnAndWait();
    if (run_term == .Exited) std.process.exit(run_term.Exited);
}

// ---------------------------------------------------------------------------
// Run mode — compile to C, generate harness, invoke cc, execute
// ---------------------------------------------------------------------------

fn runModeWithLinks(path: []const u8, link_libs: []const []const u8, engine_raylib: bool, watch_mode: bool, backing: std.mem.Allocator) !void {
    if (engine_raylib and watch_mode) {
        try runRaylibHotReload(path, link_libs, backing);
        return;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var arenas = ArenaTriple.init(backing);
    defer arenas.deinit();
    const frame_alloc = arenas.allocator(.frame);

    const prelude: ?[]const u8 = if (engine_raylib) raylib_prelude else null;
    var imported_files = std.ArrayListUnmanaged([]const u8){};
    const ir_module = try compileFileOpts(path, frame_alloc, false, &imported_files, prelude) orelse std.process.exit(1);

    // Derive output paths in a temp directory.
    const tmp_dir = try std.fmt.allocPrint(frame_alloc, "/tmp/chasm_run_{d}", .{std.time.milliTimestamp()});
    try std.fs.cwd().makePath(tmp_dir);

    // Write generated C.
    const c_path = try std.fmt.allocPrint(frame_alloc, "{s}/script.c", .{tmp_dir});
    const c_file = try std.fs.cwd().createFile(c_path, .{});
    if (engine_raylib) {
        try codegen.emitModuleRaylib(ir_module, c_file.deprecatedWriter());
    } else {
        try codegen.emitModule(ir_module, c_file.deprecatedWriter());
    }
    c_file.close();

    // Write runtime header.
    const rt_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rt.h", .{tmp_dir});
    const rt_file = try std.fs.cwd().createFile(rt_path, .{});
    try codegen.emitRuntimeHeader(rt_file.deprecatedWriter());
    rt_file.close();

    // Write chasm_rl.h when using the raylib engine.
    if (engine_raylib) {
        const rl_h_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rl.h", .{tmp_dir});
        const rl_h_file = try std.fs.cwd().createFile(rl_h_path, .{});
        try codegen.emitRaylibHeader(rl_h_file.deprecatedWriter());
        rl_h_file.close();
    }

    // Write harness.
    const harness_path = try std.fmt.allocPrint(frame_alloc, "{s}/harness.c", .{tmp_dir});
    const harness_file = try std.fs.cwd().createFile(harness_path, .{});
    const hw = harness_file.deprecatedWriter();

    if (engine_raylib) {
        // ---- Raylib game-loop harness ------------------------------------
        // Detect which hooks the script provides.
        var has_on_init   = false;
        var has_on_tick   = false;
        var has_on_draw   = false;
        var has_on_unload = false;
        for (ir_module.functions) |func| {
            if (std.mem.eql(u8, func.name, "on_init"))   has_on_init   = true;
            if (std.mem.eql(u8, func.name, "on_tick"))   has_on_tick   = true;
            if (std.mem.eql(u8, func.name, "on_draw"))   has_on_draw   = true;
            if (std.mem.eql(u8, func.name, "on_unload")) has_on_unload = true;
        }
        try hw.print("#include \"chasm_rl.h\"\n\n", .{});
        try hw.print("void chasm_module_init(ChasmCtx *ctx);\n", .{});
        if (has_on_tick)   try hw.print("void chasm_on_tick(ChasmCtx *ctx, double dt);\n", .{});
        if (has_on_draw)   try hw.print("void chasm_on_draw(ChasmCtx *ctx);\n", .{});
        if (has_on_init) {
            try hw.print("void chasm_on_init(ChasmCtx *ctx);\n", .{});
        } else {
            try hw.print("static void chasm_on_init(ChasmCtx *ctx) {{ (void)ctx; }}\n", .{});
        }
        if (has_on_unload) {
            try hw.print("void chasm_on_unload(ChasmCtx *ctx);\n", .{});
        } else {
            try hw.print("static void chasm_on_unload(ChasmCtx *ctx) {{ (void)ctx; }}\n", .{});
        }
        try hw.print(
            \\
            \\int main(void) {{
            \\    static uint8_t frame_mem  [ 1*1024*1024];
            \\    static uint8_t script_mem [ 4*1024*1024];
            \\    static uint8_t persist_mem[16*1024*1024];
            \\    ChasmCtx ctx = {{
            \\        .frame      = {{frame_mem,   0, sizeof(frame_mem)}},
            \\        .script     = {{script_mem,  0, sizeof(script_mem)}},
            \\        .persistent = {{persist_mem, 0, sizeof(persist_mem)}},
            \\    }};
            \\    chasm_module_init(&ctx);
            \\    InitWindow(800, 600, "Chasm Game");
            \\    SetTargetFPS(60);
            \\    chasm_on_init(&ctx);
            \\    while (!WindowShouldClose()) {{
            \\        double dt = (double)GetFrameTime();
            \\
            , .{});
        if (has_on_tick) try hw.print("        chasm_on_tick(&ctx, dt);\n", .{});
        try hw.print(
            \\        BeginDrawing();
            \\        ClearBackground((Color){{0,0,0,255}});
            \\
            , .{});
        if (has_on_draw) try hw.print("        chasm_on_draw(&ctx);\n", .{});
        try hw.print(
            \\        EndDrawing();
            \\        chasm_clear_frame(&ctx);
            \\    }}
            \\    chasm_on_unload(&ctx);
            \\    CloseWindow();
            \\    return 0;
            \\}}
            \\
            , .{});
    } else {
        // ---- Standard harness: call main if present, else all public zero-arg fns -------
        try hw.print("#include \"chasm_rt.h\"\n#include <stdio.h>\n#include <stdlib.h>\n\n", .{});
        // Determine if a `main` function exists.
        var has_main = false;
        for (ir_module.functions) |func| {
            if (std.mem.eql(u8, func.name, "main") and func.is_public and func.params.len == 0) {
                has_main = true;
                break;
            }
        }
        var has_callable = false;
        for (ir_module.functions) |func| {
            if (!func.is_public or func.params.len > 0) continue;
            if (has_main and !std.mem.eql(u8, func.name, "main")) continue;
            try hw.print("void chasm_{s}(ChasmCtx *ctx);\n", .{func.name});
            has_callable = true;
        }
        try hw.print("void chasm_module_init(ChasmCtx *ctx);\n\n", .{});
        try hw.print(
            \\int main(void) {{
            \\    uint8_t frame_mem[64*1024], script_mem[64*1024], persist_mem[256*1024];
            \\    ChasmCtx ctx = {{
            \\        .frame      = {{frame_mem,   0, sizeof(frame_mem)}},
            \\        .script     = {{script_mem,  0, sizeof(script_mem)}},
            \\        .persistent = {{persist_mem, 0, sizeof(persist_mem)}},
            \\    }};
            \\    chasm_module_init(&ctx);
            \\
            , .{});
        for (ir_module.functions) |func| {
            if (!func.is_public or func.params.len > 0) continue;
            if (has_main and !std.mem.eql(u8, func.name, "main")) continue;
            try hw.print("    chasm_{s}(&ctx);\n", .{func.name});
            try hw.print("    chasm_clear_frame(&ctx);\n", .{});
        }
        if (!has_callable) {
            try hw.print("    printf(\"(no public zero-argument functions to call)\\n\");\n", .{});
        }
        try hw.print(
            \\    return 0;
            \\}}
            \\
            , .{});
    }
    harness_file.close();

    // Compile imported modules to C files.
    var imported_c_paths = std.ArrayListUnmanaged([]const u8){};
    defer imported_c_paths.deinit(backing);
    for (imported_files.items) |imp_path| {
        const imp_module = try compileFileOpts(imp_path, frame_alloc, false, null, null) orelse continue;
        const imp_c_path = try std.fmt.allocPrint(frame_alloc, "{s}/imported_{d}.c", .{ tmp_dir, imported_c_paths.items.len });
        const imp_c_file = try std.fs.cwd().createFile(imp_c_path, .{});
        const imp_mod_name = std.fs.path.stem(imp_path);
        try codegen.emitModuleImported(imp_module, imp_mod_name, imp_c_file.deprecatedWriter());
        imp_c_file.close();
        try imported_c_paths.append(backing, imp_c_path);
    }

    // Compile.
    const bin_path = try std.fmt.allocPrint(frame_alloc, "{s}/out", .{tmp_dir});
    var cc_argv_list = std.ArrayListUnmanaged([]const u8){};
    defer cc_argv_list.deinit(backing);
    // Imported C files go first so their declarations are visible to the main script.
    try cc_argv_list.appendSlice(backing, &.{ "cc", "-o", bin_path });
    for (imported_c_paths.items) |icp| {
        try cc_argv_list.append(backing, icp);
    }
    try cc_argv_list.appendSlice(backing, &.{ c_path, harness_path, "-I", tmp_dir });
    for (link_libs) |lib| {
        const flag = try std.fmt.allocPrint(frame_alloc, "-l{s}", .{lib});
        try cc_argv_list.append(backing, flag);
    }
    if (engine_raylib) {
        // Find raylib: try cwd-relative paths first, then fall back to exe-relative.
        const raylib_dir: []const u8 = blk: {
            // Running from project root: engine/raylib-5.5_macos
            std.fs.cwd().access("engine/raylib-5.5_macos", .{}) catch {
                // Running from inside engine/: raylib-5.5_macos
                std.fs.cwd().access("raylib-5.5_macos", .{}) catch {
                    // Fall back to path relative to the executable.
                    const exe_dir = std.fs.selfExeDirPathAlloc(backing) catch break :blk "engine/raylib-5.5_macos";
                    defer backing.free(exe_dir);
                    const alt = try std.fmt.allocPrint(frame_alloc, "{s}/../../engine/raylib-5.5_macos", .{exe_dir});
                    break :blk alt;
                };
                break :blk "raylib-5.5_macos";
            };
            break :blk "engine/raylib-5.5_macos";
        };
        const inc = try std.fmt.allocPrint(frame_alloc, "{s}/include", .{raylib_dir});
        const lib = try std.fmt.allocPrint(frame_alloc, "{s}/lib", .{raylib_dir});
        const static_lib = try std.fmt.allocPrint(frame_alloc, "{s}/libraylib.a", .{lib});
        try cc_argv_list.appendSlice(backing, &.{ "-I", inc, static_lib });
        // macOS system frameworks required by raylib.
        if (builtin.os.tag == .macos) {
            try cc_argv_list.appendSlice(backing, &.{
                "-framework", "OpenGL",
                "-framework", "Cocoa",
                "-framework", "IOKit",
                "-framework", "CoreVideo",
                "-framework", "CoreAudio",
                "-framework", "AudioToolbox",
            });
        } else if (builtin.os.tag == .linux) {
            try cc_argv_list.appendSlice(backing, &.{ "-lGL", "-lm", "-lpthread", "-ldl", "-lrt", "-lX11" });
        }
    }
    var cc_proc = std.process.Child.init(cc_argv_list.items, backing);
    cc_proc.stderr_behavior = .Inherit;
    const cc_term = try cc_proc.spawnAndWait();
    if (cc_term != .Exited or cc_term.Exited != 0) {
        try stderr.print("chasm run: cc failed\n", .{});
        std.process.exit(1);
    }

    try stdout.print("  running {s}...\n\n", .{path});

    // Execute.
    const run_argv = [_][]const u8{bin_path};
    var run_proc = std.process.Child.init(&run_argv, backing);
    run_proc.stdout_behavior = .Inherit;
    run_proc.stderr_behavior = .Inherit;
    const run_term = try run_proc.spawnAndWait();
    if (run_term == .Exited) std.process.exit(run_term.Exited);
}

fn usage() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print(
        \\Usage:
        \\  chasm run <file.chasm> [--link lib]  — compile and run immediately
        \\  chasm compile <file.chasm> [--link lib] — compile to C (with link hint)
        \\  chasm <file.chasm>                   — compile to C
        \\  chasm compare <old.chasm> <new>      — show hot-reload diff
        \\  chasm --watch <file.chasm>           — watch + recompile on change
        \\  chasm --version                      — print version
        \\
        , .{});
}
