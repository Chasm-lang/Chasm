// cmd/chasm — Chasm compiler CLI driver.
//
// Implements: compile, run, watch, version.
// Compilation pipeline:
//   1. Write source (+ optional prelude) to /tmp/sema_combined.chasm
//   2. Run the bootstrap binary → /tmp/chasm_out.c, /tmp/chasm_rt.h
//   3. cc-compile with the appropriate harness
//   4. exec (for run/watch)
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
	buildAndRun(path, opts, false)
}

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
			if !lastMod.IsZero() {
				fmt.Printf("\n[watch] %s changed — recompiling...\n", path)
			}
			lastMod = info.ModTime()
			buildAndRun(path, opts, true)
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
	src, err := os.ReadFile(path)
	if err != nil {
		fatalf("read %s: %v\n", path, err)
	}

	combined := src
	if opts.engineRaylib {
		prelude, err := os.ReadFile(raylibChasmPath())
		if err != nil {
			fatalf("read raylib prelude: %v\n", err)
		}
		combined = append(prelude, append([]byte("\n"), src...)...)
	}

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
func buildAndRun(path string, opts options, quiet bool) {
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

static uint8_t frame_mem  [ 1 * 1024 * 1024];
static uint8_t script_mem [ 4 * 1024 * 1024];
static uint8_t persist_mem[16 * 1024 * 1024];

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
	if h := os.Getenv("CHASM_HOME"); h != "" {
		return h
	}
	exe, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(exe)
		for i := 0; i < 8; i++ {
			if _, err := os.Stat(filepath.Join(dir, "bootstrap")); err == nil {
				return dir
			}
			dir = filepath.Dir(dir)
		}
	}
	// Last resort: current working directory.
	cwd, _ := os.Getwd()
	return cwd
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

func engineDir() string {
	return filepath.Join(chasmHome(), "engine")
}

func raylibDir() string {
	// Prefer OS-arch specific directory.
	base := engineDir()
	entries, _ := filepath.Glob(filepath.Join(base, "raylib-*_macos"))
	if len(entries) > 0 {
		return entries[0]
	}
	return filepath.Join(base, "raylib-5.5_macos")
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
