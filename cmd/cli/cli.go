// cmd/chasm — Chasm compiler CLI driver.
//
// Implements: compile, run, watch, version.
// Compilation pipeline:
//  1. Write source (+ optional prelude) to <tmpdir>/sema_combined.chasm
//  2. Run the bootstrap binary on sema_combined.chasm → stdout → <tmpdir>/chasm_out.c
//  3. cc-compile with the appropriate harness
//  4. exec (for run/watch)
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const version = "1.9.0"

// tmpPath returns a path inside the temp directory used by the bootstrap binary.
// On Unix the bootstrap binary hardcodes /tmp, so we match that.
// On Windows there is no /tmp; use the OS temp dir instead (requires a
// Windows-native bootstrap binary compiled with the matching path).
func tmpPath(name string) string {
	if runtime.GOOS == "windows" {
		return filepath.Join(os.TempDir(), name)
	}
	return filepath.Join("/tmp", name)
}

// defaultChasmHome is baked in at build time by install.sh:
//
//	go build -ldflags "-X main.defaultChasmHome=/path/to/repo"
//
// Falls back to CHASM_HOME env var or executable-walk detection.
var defaultChasmHome string

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	switch os.Args[1] {
	case "version", "--version", "-v":
		fmt.Printf("chasm %s\n", version)
	case "compile":
		runCompile(os.Args[2:])
	case "run":
		runRun(os.Args[2:])
	case "watch":
		runWatch(os.Args[2:])
	case "fmt":
		runFmt(os.Args[2:])
	case "help", "--help", "-h":
		usage()
	default:
		fatalf("unknown command %q — run 'chasm help'\n", os.Args[1])
	}
}

// ---------------------------------------------------------------------------
// Sub-commands
// ---------------------------------------------------------------------------

func runCompile(args []string) {
	path, opts := parseArgs(args)
	if path == "" {
		fatalf("usage: chasm compile <file.chasm> [--engine raylib|godot] [--target wasm]\n")
	}
	outC, err := compileChasm(path, opts)
	if err != nil {
		fatalf("compile: %v\n", err)
	}
	ext := ".c"
	if opts.targetWasm {
		ext = ".wat"
	}
	dst := replaceExt(path, ext)
	if err := copyFile(outC, dst); err != nil {
		fatalf("compile: %v\n", err)
	}
	fmt.Printf("  output → %s\n", dst)
	if opts.targetWasm {
		fmt.Println("  assemble: wat2wasm " + dst + " -o " + replaceExt(path, ".wasm"))
	}
}

func runRun(args []string) {
	path, opts := parseArgs(args)
	if path == "" {
		fatalf("usage: chasm run <file.chasm> [--engine raylib] [--watch]\n")
	}
	buildAndRun(path, opts, false, nil)
}

func runWatch(args []string) {
	if len(args) == 0 {
		fatalf("usage: chasm watch <file.chasm> [--engine raylib]\n")
	}
	path, opts := parseArgs(args)

	// Non-raylib watch: legacy kill-and-restart behaviour.
	if !opts.engineRaylib {
		runWatchLegacy(path, opts)
		return
	}

	// Raylib watch: hot-reload via sentinel file.
	fmt.Printf("[watch] %s (hot-reload mode)\n", path)

	// Initial compile to shared library.
	initialDylib, err := compileSharedLib(path, opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[watch] initial compile failed: %v\n", err)
		fmt.Fprintf(os.Stderr, "[watch] waiting for a fix before starting engine...\n")
		for {
			time.Sleep(300 * time.Millisecond)
			if _, statErr := os.Stat(path); statErr != nil {
				continue
			}
			if initialDylib, err = compileSharedLib(path, opts); err == nil {
				break
			}
		}
	}

	// Build engine binary (once).
	engineBin, err := buildEngineOnly()
	if err != nil {
		fatalf("build engine: %v\n", err)
	}

	// Start engine, passing the initial dylib path as argv[1].
	engineProc := exec.Command(engineBin, initialDylib)
	engineProc.Stdout = os.Stdout
	engineProc.Stderr = os.Stderr
	if err := engineProc.Start(); err != nil {
		fatalf("start engine: %v\n", err)
	}
	fmt.Printf("[watch] engine started (pid %d)\n", engineProc.Process.Pid)

	// Monitor engine exit in background.
	engineDone := make(chan error, 1)
	go func() { engineDone <- engineProc.Wait() }()

	// Handle SIGINT/SIGTERM: forward to engine and exit.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)
	go func() {
		<-sigCh
		if engineProc.Process != nil {
			_ = engineProc.Process.Signal(os.Interrupt)
		}
		os.Exit(0)
	}()

	var lastMod time.Time
	for {
		select {
		case exitErr := <-engineDone:
			if exitErr != nil {
				fmt.Fprintf(os.Stderr, "[watch] engine exited: %v\n", exitErr)
			} else {
				fmt.Fprintf(os.Stderr, "[watch] engine exited cleanly\n")
			}
			return
		default:
		}

		info, statErr := os.Stat(path)
		if statErr != nil {
			time.Sleep(300 * time.Millisecond)
			continue
		}

		if info.ModTime().After(lastMod) {
			if !lastMod.IsZero() {
				ts := time.Now().Format("15:04:05")
				fmt.Printf("[%s] %s changed — recompiling...\n", ts, path)
				if newDylib, compErr := compileSharedLib(path, opts); compErr != nil {
					fmt.Fprintf(os.Stderr, "[%s] compile error: %v\n", ts, compErr)
				} else {
					fmt.Printf("[%s] compiled OK — signalling engine\n", ts)
					if sentErr := writeReloadSentinel(newDylib); sentErr != nil {
						fmt.Fprintf(os.Stderr, "[%s] sentinel write failed: %v\n", ts, sentErr)
					}
				}
			}
			lastMod = info.ModTime()
		}

		time.Sleep(300 * time.Millisecond)
	}
}

// runWatchLegacy is the original kill-and-restart watch for non-raylib targets.
func runWatchLegacy(path string, opts options) {
	fmt.Printf("[watch] %s\n", path)
	var runningProc *exec.Cmd
	var lastMod time.Time
	for {
		info, err := os.Stat(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[watch] stat: %v\n", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}
		if info.ModTime().After(lastMod) {
			if runningProc != nil && runningProc.Process != nil {
				_ = runningProc.Process.Kill()
				_ = runningProc.Wait()
				runningProc = nil
			}
			if !lastMod.IsZero() {
				fmt.Printf("\n[watch] %s changed — recompiling...\n", path)
			}
			lastMod = info.ModTime()
			buildAndRun(path, opts, true, &runningProc)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------
// Core pipeline
// ---------------------------------------------------------------------------

// compileChasm runs the bootstrap binary on path and returns the path to the
// generated /tmp/chasm_out.c (or .wat). Calls fatalf on unrecoverable errors
// (missing bootstrap binary, missing source file). Returns an error if the
// bootstrap compiler itself fails (e.g. syntax error in source).
func compileChasm(path string, opts options) (string, error) {
	home := chasmHome()
	visited := map[string]bool{}

	var combined []byte
	if opts.engineRaylib {
		prelude, err := resolveImports(raylibChasmPath(), home, visited)
		if err != nil {
			fatalf("raylib prelude: %v\n", err)
		}
		combined = append(combined, prelude...)
		combined = append(combined, '\n')
	} else if opts.engineGodot {
		prelude, err := resolveImports(godotChasmPath(), home, visited)
		if err != nil {
			fatalf("godot prelude: %v\n", err)
		}
		combined = append(combined, prelude...)
		combined = append(combined, '\n')
	}

	src, err := resolveImports(path, home, visited)
	if err != nil {
		fatalf("%v\n", err)
	}
	combined = append(combined, src...)

	if err := os.WriteFile(tmpPath("sema_combined.chasm"), combined, 0644); err != nil {
		fatalf("write sema_combined.chasm: %v\n", err)
	}

	// Bootstrap binary reads sema_combined.chasm and chasm_target.txt from the
	// OS temp dir, then writes generated C (or WAT) to stdout.
	target := "c99"
	if opts.targetWasm {
		target = "wasm"
	}
	if err := os.WriteFile(tmpPath("chasm_target.txt"), []byte(target), 0644); err != nil {
		fatalf("write chasm_target.txt: %v\n", err)
	}

	outPath := tmpPath("chasm_out.c")
	if opts.targetWasm {
		outPath = tmpPath("chasm_out.wat")
	}
	bootstrap := bootstrapBin()
	cmd := exec.Command(bootstrap)
	outFile, err := os.Create(outPath)
	if err != nil {
		fatalf("create %s: %v\n", outPath, err)
	}
	defer outFile.Close()
	cmd.Stdout = outFile
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("bootstrap compiler: %w", err)
	}

	// Always write the runtime header from the repo (keeps it up to date).
	rtSrc := filepath.Join(chasmHome(), "runtime", "chasm_rt.h")
	if err := copyFile(rtSrc, tmpPath("chasm_rt.h")); err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not copy chasm_rt.h: %v\n", err)
	}

	return outPath, nil
}

// buildAndRun compiles and executes the result.
// If quiet is true, build errors still print but run errors are suppressed.
// If procOut is non-nil, the process is started in background and stored there.
func buildAndRun(path string, opts options, quiet bool, procOut **exec.Cmd) {
	// Raylib mode: compile to dylib + run via engine binary (same as watch).
	if opts.engineRaylib {
		dylibPath, err := compileSharedLib(path, opts)
		if err != nil {
			if !quiet {
				fatalf("compile: %v\n", err)
			}
			fmt.Fprintf(os.Stderr, "[watch] compile error: %v\n", err)
			return
		}
		engineBin, err := buildEngineOnly()
		if err != nil {
			if !quiet {
				fatalf("build engine: %v\n", err)
			}
			return
		}
		run := exec.Command(engineBin, dylibPath)
		run.Stdin = os.Stdin
		run.Stdout = os.Stdout
		run.Stderr = os.Stderr
		if procOut != nil {
			if err := run.Start(); err != nil && !quiet {
				fmt.Fprintf(os.Stderr, "run: %v\n", err)
			}
			*procOut = run
			return
		}
		if err := run.Run(); err != nil && !quiet {
			fmt.Fprintf(os.Stderr, "run: %v\n", err)
		}
		return
	}

	// Standalone (non-raylib) mode.
	outC, err := compileChasm(path, opts)
	if err != nil {
		if !quiet {
			fatalf("compile: %v\n", err)
		}
		fmt.Fprintf(os.Stderr, "[watch] compile error: %v\n", err)
		return
	}

	binPath := tmpPath("chasm_run_out")
	harnessC := writeStandaloneHarness()
	ccArgs := []string{"cc", "-o", binPath, outC, harnessC, "-I" + tmpPath("")}

	cc := exec.Command(ccArgs[0], ccArgs[1:]...)
	cc.Stdout = os.Stdout
	var ccStderr strings.Builder
	cc.Stderr = &ccStderr
	if err := cc.Run(); err != nil {
		filterCCErrors([]byte(ccStderr.String()), path)
		if !quiet {
			fatalf("cc failed\n")
		}
		return
	}

	run := exec.Command(binPath)
	run.Stdin = os.Stdin
	run.Stdout = os.Stdout
	run.Stderr = os.Stderr
	if procOut != nil {
		if err := run.Start(); err != nil && !quiet {
			fmt.Fprintf(os.Stderr, "run: %v\n", err)
		}
		*procOut = run
		return
	}
	if err := run.Run(); err != nil && !quiet {
		fmt.Fprintf(os.Stderr, "run: %v\n", err)
	}
}

// compileSharedLib compiles the Chasm script to a uniquely-named shared library
// (.dylib / .so) to avoid macOS dylib caching. Returns the output path on success.
func compileSharedLib(path string, opts options) (string, error) {
	outC, err := compileChasm(path, opts)
	if err != nil {
		return "", err
	}

	// Remove chasm_rt.h from temp so the generated code's #include "chasm_rt.h"
	// falls through to -I engine/ and finds the engine's copy.
	_ = os.Remove(tmpPath("chasm_rt.h"))

	var ext string
	var sharedArgs []string
	switch runtime.GOOS {
	case "darwin":
		ext = ".dylib"
		sharedArgs = []string{"-dynamiclib", "-undefined", "dynamic_lookup"}
	case "windows":
		ext = ".dll"
		sharedArgs = []string{"-shared"}
	default:
		ext = ".so"
		sharedArgs = []string{"-shared", "-fPIC"}
	}

	// Unique path per compile — avoids macOS dylib caching in dlopen.
	scriptPath := tmpPath(fmt.Sprintf("chasm_script_%d%s", time.Now().UnixNano(), ext))

	var args []string
	if opts.engineGodot {
		// Godot scripts: include the godot engine dir (for chasm_godot_shim.h)
		// and the raylib dir (for chasm_rt.h / loader.h).
		// Force-include the shim so extern fns resolve to gdot_* symbols in GDE.
		godotDir := godotEngineDir()
		shimH := filepath.Join(godotDir, "chasm_godot_shim.h")
		args = []string{"cc"}
		args = append(args, sharedArgs...)
		args = append(args,
			"-o", scriptPath,
			outC,
			"-include", shimH,
			"-I"+godotDir,
			"-I"+raylibEngineDir(),
		)
	} else {
		eng := raylibEngineDir()
		rl := raylibDir()
		args = []string{"cc"}
		args = append(args, sharedArgs...)
		args = append(args,
			"-o", scriptPath,
			outC,
			"-I"+eng,
			"-I"+filepath.Join(rl, "include"),
		)
	}

	cc := exec.Command(args[0], args[1:]...)
	cc.Stdout = os.Stdout
	var ccStderr strings.Builder
	cc.Stderr = &ccStderr
	if err := cc.Run(); err != nil {
		filterCCErrors([]byte(ccStderr.String()), path)
		return "", err
	}
	return scriptPath, nil
}

// buildEngineOnly compiles engine/main.c (with loader.h) to a standalone binary.
// The binary is cached next to the engine sources as engine/.chasm_engine_cache
// so it survives reboots. Skips rebuild if the binary is newer than all engine
// source files. The script is NOT linked in — loaded via dlopen.
func buildEngineOnly() (string, error) {
	eng := raylibEngineDir()
	rl := raylibDir()
	mainC := filepath.Join(eng, "main.c")
	exportsC := filepath.Join(eng, "chasm_rl_exports.c")
	loaderH := filepath.Join(eng, "loader.h")
	binPath := filepath.Join(eng, ".chasm_engine_cache")

	// Cache check: skip rebuild if binary is newer than all source files.
	if binInfo, err := os.Stat(binPath); err == nil {
		binMod := binInfo.ModTime()
		stale := false
		for _, src := range []string{mainC, exportsC, loaderH} {
			if info, err := os.Stat(src); err == nil && info.ModTime().After(binMod) {
				stale = true
				break
			}
		}
		if !stale {
			return binPath, nil
		}
	}

	fmt.Println("[watch] building engine binary...")
	args := []string{
		"cc", "-O0", "-o", binPath,
		mainC, exportsC,
		"-I" + eng,
		"-I" + filepath.Join(rl, "include"),
		filepath.Join(rl, "lib", "libraylib.a"),
	}
	switch runtime.GOOS {
	case "darwin":
		args = append(args,
			"-framework", "OpenGL",
			"-framework", "Cocoa",
			"-framework", "IOKit",
			"-framework", "CoreVideo",
			"-framework", "CoreAudio",
			"-framework", "AudioToolbox",
		)
	case "windows":
		args = append(args, "-lopengl32", "-lgdi32", "-lwinmm", "-lcomdlg32")
	default: // Linux
		args = append(args, "-lGL", "-lm", "-lpthread", "-ldl", "-lrt", "-lX11")
	}

	cc := exec.Command(args[0], args[1:]...)
	cc.Stdout = os.Stdout
	cc.Stderr = os.Stderr
	if err := cc.Run(); err != nil {
		return "", err
	}
	return binPath, nil
}

// writeReloadSentinel writes the dylib path into the sentinel file.
// The engine reads the path from the file, then unlinks it.
func writeReloadSentinel(dylibPath string) error {
	return os.WriteFile(tmpPath("chasm_reload_ready"), []byte(dylibPath), 0644)
}

func buildEngineCC(scriptC, binPath string) []string {
	eng := raylibEngineDir()
	rl := raylibDir()
	mainC := filepath.Join(eng, "main.c")
	shimH := filepath.Join(eng, "chasm_rl_shim.h")

	// Remove chasm_rt.h from temp so the generated code's #include "chasm_rt.h"
	// falls through to -I engine/ and finds the engine's copy — avoiding double-include.
	_ = os.Remove(tmpPath("chasm_rt.h"))

	args := []string{
		"cc", "-o", binPath,
		scriptC, mainC,
		// Force-include the shim so chasm_*(ctx,...) calls map to rl_*() functions.
		"-include", shimH,
		"-I" + eng,
		"-I" + filepath.Join(rl, "include"),
		filepath.Join(rl, "lib", "libraylib.a"),
	}
	switch runtime.GOOS {
	case "darwin":
		args = append(args,
			"-framework", "OpenGL",
			"-framework", "Cocoa",
			"-framework", "IOKit",
			"-framework", "CoreVideo",
			"-framework", "CoreAudio",
			"-framework", "AudioToolbox",
		)
	case "windows":
		args = append(args, "-lopengl32", "-lgdi32", "-lwinmm", "-lcomdlg32")
	default: // Linux
		args = append(args, "-lGL", "-lm", "-lpthread", "-ldl", "-lrt", "-lX11")
	}
	return args
}

// writeStandaloneHarness writes a minimal main.c to /tmp and returns its path.
func writeStandaloneHarness() string {
	const harness = `#include "chasm_rt.h"
#include <stdint.h>

/* Generated by chasm CLI — standalone harness */

/* Weak stubs: defined here so linking succeeds even if the script doesn't
   provide them. The compiled script's definitions take priority. */
__attribute__((weak)) void chasm_module_init(ChasmCtx *ctx) { (void)ctx; }
__attribute__((weak)) void chasm_main(ChasmCtx *ctx) { (void)ctx; }

static uint8_t frame_mem  [16 * 1024 * 1024];
static uint8_t script_mem [32 * 1024 * 1024];
static uint8_t persist_mem[64 * 1024 * 1024];

int main(void) {
    ChasmCtx ctx = {
        .frame      = { frame_mem,   0, sizeof(frame_mem)   },
        .script     = { script_mem,  0, sizeof(script_mem)  },
        .persistent = { persist_mem, 0, sizeof(persist_mem) },
    };
    chasm_module_init(&ctx);
    chasm_main(&ctx);
    return 0;
}
`
	path := tmpPath("chasm_harness.c")
	if err := os.WriteFile(path, []byte(harness), 0644); err != nil {
		fatalf("write harness: %v\n", err)
	}
	return path
}

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

// chasmHome returns the root of the Chasm repo/install.
// Checks $CHASM_HOME first, then walks up from the running executable
// looking for a bootstrap/ directory.
func chasmHome() string {
	// 1. Explicit env override always wins.
	if h := os.Getenv("CHASM_HOME"); h != "" {
		return h
	}
	// 2. Path baked in at build time by install.sh.
	if defaultChasmHome != "" {
		if _, err := os.Stat(filepath.Join(defaultChasmHome, "bootstrap")); err == nil {
			return defaultChasmHome
		}
	}
	// 3. Walk up from the executable (works when running from the repo).
	exe, err := os.Executable()
	if err == nil {
		// Resolve symlinks so the walk works even if the binary is symlinked.
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		dir := filepath.Dir(exe)
		for i := 0; i < 10; i++ {
			if _, err := os.Stat(filepath.Join(dir, "bootstrap")); err == nil {
				return dir
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	fatalf("cannot locate Chasm repo.\n\nSet CHASM_HOME to the repo root and try again:\n  export CHASM_HOME=/path/to/chasm\n\nOr reinstall with:\n  cd /path/to/chasm && ./install.sh\n")
	return ""
}

func bootstrapBin() string {
	home := chasmHome()
	arch := runtime.GOARCH
	os_ := runtime.GOOS
	name := fmt.Sprintf("chasm-%s-%s", os_, arch)
	// Normalise to match the file naming convention.
	name = strings.ReplaceAll(name, "darwin", "macos")
	name = strings.ReplaceAll(name, "amd64", "x86_64")
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	bin := filepath.Join(home, "bootstrap", "bin", name)
	if _, err := os.Stat(bin); err != nil {
		fatalf("bootstrap binary not found: %s\n  Set CHASM_HOME to the chasm repo root.\n", bin)
	}
	return bin
}

// resolveImports returns the fully-expanded source for path with all imports
// inlined in dependency order. visited tracks resolved absolute paths to
// prevent duplicates and cycles.
func resolveImports(path string, home string, visited map[string]bool) ([]byte, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if visited[abs] {
		return nil, nil // already included
	}
	visited[abs] = true

	raw, err := os.ReadFile(abs)
	if err != nil {
		return nil, fmt.Errorf("import %q: %w", path, err)
	}

	var out []byte
	for _, line := range strings.Split(string(raw), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "import ") {
			rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "import "))
			if len(rest) >= 2 && rest[0] == '"' {
				if end := strings.Index(rest[1:], "\""); end >= 0 {
					importPath := rest[1 : end+1]
					resolved := resolveImportPath(importPath, filepath.Dir(abs), home)
					chunk, err := resolveImports(resolved, home, visited)
					if err != nil {
						return nil, err
					}
					out = append(out, chunk...)
					out = append(out, '\n')
					continue // replace the import line with the inlined content
				}
			}
		}
		out = append(out, []byte(line)...)
		out = append(out, '\n')
	}
	return out, nil
}

// resolveImportPath resolves an import path to an absolute file path.
// Search order: 1) absolute (used as-is), 2) relative to the importing file,
// 3) $CHASM_HOME/std/.
func resolveImportPath(importPath, dir, home string) string {
	if !strings.HasSuffix(importPath, ".chasm") {
		importPath += ".chasm"
	}
	if filepath.IsAbs(importPath) {
		return importPath
	}
	rel := filepath.Join(dir, importPath)
	if _, err := os.Stat(rel); err == nil {
		return rel
	}
	return filepath.Join(home, "std", importPath)
}

func engineDir() string {
	return filepath.Join(chasmHome(), "engine")
}

func raylibEngineDir() string {
	return filepath.Join(engineDir(), "raylib")
}

func raylibDir() string {
	base := raylibEngineDir()
	// Normalise GOOS to match directory naming (darwin → macos).
	osName := runtime.GOOS
	if osName == "darwin" {
		osName = "macos"
	}
	// Try versioned directory first (e.g. raylib-5.5_macos), then plain.
	entries, _ := filepath.Glob(filepath.Join(base, "raylib-*_"+osName))
	if len(entries) > 0 {
		return entries[0]
	}
	return filepath.Join(base, "raylib-5.5_"+osName)
}

func raylibChasmPath() string {
	return filepath.Join(raylibEngineDir(), "raylib.chasm")
}

func godotEngineDir() string {
	return filepath.Join(engineDir(), "godot")
}

func godotChasmPath() string {
	return filepath.Join(godotEngineDir(), "godot.chasm")
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

type options struct {
	engineRaylib bool
	engineGodot  bool
	targetWasm   bool
}

func parseArgs(args []string) (path string, opts options) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--engine":
			if i+1 < len(args) {
				i++
				switch args[i] {
				case "raylib":
					opts.engineRaylib = true
				case "godot":
					opts.engineGodot = true
				}
			}
		case "--target":
			if i+1 < len(args) {
				i++
				if args[i] == "wasm" {
					opts.targetWasm = true
				}
			}
		case "--watch":
			// handled by caller
		default:
			if !strings.HasPrefix(args[i], "--") {
				path = args[i]
			}
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func replaceExt(path, newExt string) string {
	ext := filepath.Ext(path)
	return path[:len(path)-len(ext)] + newExt
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "chasm: "+format, args...)
	os.Exit(1)
}

// filterCCErrors captures cc stderr and reformats clang-style diagnostics into
// clean Chasm-style output. Lines referencing /tmp/chasm_out.c are translated
// to hide the internal path; other lines pass through unchanged.
//
// Format in:  /tmp/chasm_out.c:114:26: error: redefinition of 'foo'
// Format out:
//
//	error[CC]: redefinition of 'foo'
//	  --> (generated C, line 114)
func filterCCErrors(raw []byte, chasmSrc string) {
	lines := strings.Split(string(raw), "\n")
	for _, line := range lines {
		if line == "" {
			continue
		}
		// Try to match clang's  file:line:col: severity: message  pattern.
		// We only reformat lines that reference our temp file.
		if strings.HasPrefix(line, tmpPath("chasm_out.c")+":") || strings.HasPrefix(line, tmpPath("chasm_script_")) {
			// Strip the file prefix: split on first 3 colons.
			rest := line
			// Remove the file path prefix up to and including the first ':'
			if idx := strings.Index(rest, ":"); idx >= 0 {
				rest = rest[idx+1:] // "114:26: error: msg"
			}
			// Extract line number
			lineNum := ""
			if idx := strings.Index(rest, ":"); idx >= 0 {
				lineNum = rest[:idx]
				rest = rest[idx+1:] // "26: error: msg"
			}
			// Skip col number
			if idx := strings.Index(rest, ":"); idx >= 0 {
				rest = rest[idx+1:] // " error: msg"
			}
			rest = strings.TrimSpace(rest)
			// Split severity from message
			severity := "error"
			msg := rest
			if idx := strings.Index(rest, ":"); idx >= 0 {
				severity = strings.TrimSpace(rest[:idx])
				msg = strings.TrimSpace(rest[idx+1:])
			}
			if severity == "note" {
				// notes are noise from internal C — skip them
				continue
			}
			fmt.Fprintf(os.Stderr, "%s[CC]: %s\n", severity, msg)
			if lineNum != "" {
				fmt.Fprintf(os.Stderr, "  --> generated C, line %s\n", lineNum)
			}
			if chasmSrc != "" {
				fmt.Fprintf(os.Stderr, "  --> source: %s\n", chasmSrc)
			}
		} else {
			// Pass through non-temp-file lines (e.g. engine header errors)
			fmt.Fprintln(os.Stderr, line)
		}
	}
}

// runFmt formats a Chasm source file in-place.
// It uses the same formatting logic as the LSP's textDocument/formatting handler.
func runFmt(args []string) {
	if len(args) == 0 {
		fatalf("usage: chasm fmt <file.chasm>\n")
	}
	path := args[0]
	data, err := os.ReadFile(path)
	if err != nil {
		fatalf("fmt: %v\n", err)
	}
	formatted := formatSource(string(data))
	if formatted == string(data) {
		fmt.Printf("  %s — already formatted\n", path)
		return
	}
	if err := os.WriteFile(path, []byte(formatted), 0644); err != nil {
		fatalf("fmt: %v\n", err)
	}
	fmt.Printf("  %s — formatted\n", path)
}

// formatSource applies Chasm formatting rules (shared with LSP formatter).
func formatSource(src string) string {
	lines := strings.Split(src, "\n")
	var out []string

	depth := 0
	prevWasBlank := false
	prevWasTopLevel := false

	topLevelStarters := map[string]bool{
		"def": true, "defp": true, "defstruct": true, "enum": true,
	}
	blockOpeners := map[string]bool{
		"do": true, "defstruct": true,
	}
	blockClosers := map[string]bool{
		"end": true,
	}
	blockMiddle := map[string]bool{
		"else": true,
	}

	firstToken := func(line string) string {
		trimmed := strings.TrimSpace(line)
		idx := strings.IndexAny(trimmed, " \t(")
		if idx < 0 {
			return trimmed
		}
		return trimmed[:idx]
	}

	for _, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			if !prevWasBlank {
				out = append(out, "")
			}
			prevWasBlank = true
			continue
		}
		prevWasBlank = false

		fw := firstToken(trimmed)

		if topLevelStarters[fw] && len(out) > 0 && prevWasTopLevel {
			if len(out) > 0 && out[len(out)-1] != "" {
				out = append(out, "")
			}
		}

		if blockClosers[fw] {
			depth--
			if depth < 0 {
				depth = 0
			}
		}
		if blockMiddle[fw] && depth > 0 {
			depth--
		}

		indent := strings.Repeat("  ", depth)
		// Normalize :: spacing
		normalized := normalizeColonColon(trimmed)
		normalized = strings.TrimRight(normalized, " \t")
		out = append(out, indent+normalized)

		if blockOpeners[fw] {
			depth++
		}
		if blockMiddle[fw] {
			depth++
		}

		prevWasTopLevel = topLevelStarters[fw]
	}

	for len(out) > 0 && out[len(out)-1] == "" {
		out = out[:len(out)-1]
	}
	return strings.Join(out, "\n") + "\n"
}

// normalizeColonColon ensures `::` is surrounded by exactly one space.
func normalizeColonColon(line string) string {
	parts := strings.Split(line, "::")
	if len(parts) <= 1 {
		return line
	}
	for i := range parts {
		parts[i] = strings.TrimRight(parts[i], " \t")
		if i > 0 {
			parts[i] = strings.TrimLeft(parts[i], " \t")
		}
	}
	return strings.Join(parts, " :: ")
}

func usage() {
	fmt.Print(strings.TrimSpace(`
chasm — Chasm compiler

Usage:
  chasm compile <file.chasm> [--engine raylib]   compile to C
  chasm run     <file.chasm> [--engine raylib]   compile and run
  chasm watch   <file.chasm> [--engine raylib]   watch and rerun on changes
  chasm fmt     <file.chasm>                     format source file in-place
  chasm version                                  print version

Examples:
  chasm run hello.chasm
  chasm run --engine raylib examples/game/example.chasm
  chasm fmt myfile.chasm

Environment:
  CHASM_HOME   path to the chasm repo root (auto-detected if not set)
`) + "\n")
}
