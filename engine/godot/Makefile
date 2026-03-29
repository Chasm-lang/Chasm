# engine/godot/Makefile — Build the Chasm GDExtension plugin.
#
# Outputs:
#   addons/chasm/bin/chasm_gde.macos.template_debug.framework/chasm_gde   (macOS)
#   addons/chasm/bin/libchasm_gde.linux.template_debug.x86_64.so          (Linux)
#   addons/chasm/bin/chasm_gde.windows.template_debug.x86_64.dll          (Windows)
#
# Usage:
#   make                    # builds for current OS
#   make TARGET_OS=linux    # cross-build hint (requires matching toolchain)
#   make clean

# ---- Paths ---------------------------------------------------------------
REPO_ROOT   := $(shell cd ../.. && pwd)
ENGINE_DIR  := $(REPO_ROOT)/engine/godot
RAYLIB_DIR  := $(REPO_ROOT)/engine/raylib
OUT_DIR     := $(REPO_ROOT)/addons/chasm/bin

CC          ?= cc
CFLAGS      := -O2 -fPIC -std=c99 \
               -I$(ENGINE_DIR) \
               -I$(RAYLIB_DIR) \
               -Wall -Wno-unused-function

SRC         := $(ENGINE_DIR)/chasm_gde.c

# ---- Platform detection --------------------------------------------------
UNAME := $(shell uname -s)

ifeq ($(UNAME), Darwin)
    PLATFORM    := macos
    EXT         := .framework/chasm_gde
    OUTNAME     := chasm_gde.macos.template_debug.framework
    LINK_FLAGS  := -dynamiclib -undefined dynamic_lookup
    FULL_OUT    := $(OUT_DIR)/$(OUTNAME)/chasm_gde
else ifeq ($(UNAME), Linux)
    PLATFORM    := linux
    OUTNAME     := libchasm_gde.linux.template_debug.x86_64.so
    LINK_FLAGS  := -shared
    FULL_OUT    := $(OUT_DIR)/$(OUTNAME)
else
    PLATFORM    := windows
    OUTNAME     := chasm_gde.windows.template_debug.x86_64.dll
    LINK_FLAGS  := -shared
    FULL_OUT    := $(OUT_DIR)/$(OUTNAME)
endif

# ---- Targets -------------------------------------------------------------
.PHONY: all clean dirs

all: dirs $(FULL_OUT)

dirs:
	@mkdir -p $(OUT_DIR)
ifeq ($(UNAME), Darwin)
	@mkdir -p $(OUT_DIR)/$(OUTNAME)
endif

$(FULL_OUT): $(SRC) $(ENGINE_DIR)/chasm_gde_types.h $(RAYLIB_DIR)/chasm_rt.h $(RAYLIB_DIR)/loader.h
	$(CC) $(CFLAGS) $(LINK_FLAGS) -o $@ $(SRC)
	@echo "  built → $@"

clean:
	rm -f $(OUT_DIR)/libchasm_gde*.so $(OUT_DIR)/chasm_gde*.dll
	rm -rf $(OUT_DIR)/chasm_gde*.framework
