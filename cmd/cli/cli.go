// cmd/chasm — Chasm compiler CLI driver.
//
// Implements: compile, run, watch, version.
// Compilation pipeline:
//  1. Write source (+ optional prelude) to /tmp/sema_combined.chasm
//  2. Run the bootstrap binary → /tmp/chasm_out.c, /tmp/chasm_rt.h
//  3. cc-compile with the appropriate harness
//  4. exec (for run/watch)
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const version = "0.2.0"

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
		fatalf("usage: chasm compile <file.chasm> [--engine raylib]\n")
	}
	outC := compileChasm(path, opts)
	// Copy to <basename>.c next to the source.
	dst := replaceExt(path, ".c")
	if err := copyFile(outC, dst); err != nil {
		fatalf("compile: %v\n", err)
	}
	fmt.Printf("  output → %s\n", dst)
}

func runRun(args []string) {
	path, opts := parseArgs(args)
	if path == "" {
		fatalf("usage: chasm run <file.chasm> [--engine raylib] [--watch]\n")
	}
	buildAndRun(path, opts, false, nil)
}

// runningProc holds the currently running game process for watch mode
var runningProc *exec.Cmd

func runWatch(args []string) {
	if len(args) == 0 {
		fatalf("usage: chasm watch <file.chasm> [--engine raylib]\n")
	}
	path, opts := parseArgs(args)
	fmt.Printf("[watch] %s\n", path)
	var lastMod time.Time
	for {
		info, err := os.Stat(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[watch] stat: %v\n", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}
		if info.ModTime().After(lastMod) {
			// Kill previous process if running
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
// generated /tmp/chasm_out.c.
func compileChasm(path string, opts options) string {
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
	}

	src, err := resolveImports(path, home, visited)
	if err != nil {
		fatalf("%v\n", err)
	}
	combined = append(combined, src...)

	if err := os.WriteFile("/tmp/sema_combined.chasm", combined, 0644); err != nil {
		fatalf("write /tmp/sema_combined.chasm: %v\n", err)
	}

	bootstrap := bootstrapBin()
	cmd := exec.Command(bootstrap)
	// Bootstrap binary writes generated C to stdout; capture it.
	outFile, err := os.Create("/tmp/chasm_out.c")
	if err != nil {
		fatalf("create /tmp/chasm_out.c: %v\n", err)
	}
	defer outFile.Close()
	cmd.Stdout = outFile
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fatalf("bootstrap compiler failed: %v\n", err)
	}

	// Always write the runtime header from the repo (keeps it up to date).
	rtSrc := filepath.Join(chasmHome(), "runtime", "chasm_rt.h")
	if err := copyFile(rtSrc, "/tmp/chasm_rt.h"); err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not copy chasm_rt.h: %v\n", err)
	}

	return "/tmp/chasm_out.c"
}

// buildAndRun compiles and executes the result.
// If quiet is true, build errors still print but run errors are suppressed.
// If procOut is non-nil, the process is started in background and stored there.
func buildAndRun(path string, opts options, quiet bool, procOut **exec.Cmd) {
	outC := compileChasm(path, opts)

	binPath := "/tmp/chasm_run_out"

	var ccArgs []string
	if opts.engineRaylib {
		ccArgs = buildEngineCC(outC, binPath)
	} else {
		harnessC := writeStandaloneHarness()
		ccArgs = []string{"cc", "-o", binPath, outC, harnessC, "-I/tmp"}
	}

	cc := exec.Command(ccArgs[0], ccArgs[1:]...)
	cc.Stdout = os.Stdout
	cc.Stderr = os.Stderr
	if err := cc.Run(); err != nil {
		if !quiet {
			fatalf("cc failed: %v\n", err)
		}
		return
	}

	run := exec.Command(binPath)
	run.Stdin = os.Stdin
	run.Stdout = os.Stdout
	run.Stderr = os.Stderr

	// If procOut is provided, start in background for watch mode
	if procOut != nil {
		if err := run.Start(); err != nil && !quiet {
			fmt.Fprintf(os.Stderr, "run: %v\n", err)
		}
		*procOut = run
		return
	}

	// Otherwise run synchronously
	if err := run.Run(); err != nil && !quiet {
		fmt.Fprintf(os.Stderr, "run: %v\n", err)
	}
}

// buildEngineCC returns the cc argument list for linking with the Raylib engine.
func buildEngineCC(scriptC, binPath string) []string {
	eng := engineDir()
	rl := raylibDir()
	mainC := filepath.Join(eng, "main.c")
	shimH := filepath.Join(eng, "chasm_rl_shim.h")

	// Remove /tmp/chasm_rt.h so the generated code's #include "chasm_rt.h" falls
	// through to -I engine/ and finds the engine's copy — avoiding double-include.
	_ = os.Remove("/tmp/chasm_rt.h")

	args := []string{
		"cc", "-o", binPath,
		scriptC, mainC,
		// Force-include the shim so chasm_*(ctx,...) calls map to rl_*() functions.
		"-include", shimH,
		"-I" + eng,
		"-I" + filepath.Join(rl, "include"),
		filepath.Join(rl, "lib", "libraylib.a"),
	}
	if runtime.GOOS == "darwin" {
		args = append(args,
			"-framework", "OpenGL",
			"-framework", "Cocoa",
			"-framework", "IOKit",
			"-framework", "CoreVideo",
			"-framework", "CoreAudio",
			"-framework", "AudioToolbox",
		)
	} else {
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
	path := "/tmp/chasm_harness.c"
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

func raylibDir() string {
	base := engineDir()
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
	return filepath.Join(engineDir(), "raylib.chasm")
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

type options struct {
	engineRaylib bool
}

func parseArgs(args []string) (path string, opts options) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--engine":
			if i+1 < len(args) {
				i++
				if args[i] == "raylib" {
					opts.engineRaylib = true
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

func usage() {
	fmt.Print(strings.TrimSpace(`
chasm — Chasm compiler

Usage:
  chasm compile <file.chasm> [--engine raylib]   compile to C
  chasm run     <file.chasm> [--engine raylib]   compile and run
  chasm watch   <file.chasm> [--engine raylib]   watch and rerun on changes
  chasm version                                  print version

Examples:
  chasm run hello.chasm
  chasm run --engine raylib examples/game/example.chasm

Environment:
  CHASM_HOME   path to the chasm repo root (auto-detected if not set)
`) + "\n")
}
