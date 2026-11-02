# Makefile for the Grafi NIF: C++ (via fine) wrapping igraph >= 1.0.
#
# igraph is optional. When it is missing, older than 1.0, or built without
# thread safety, the build prints a notice, writes
# $(PRIV_DIR)/.grafi_nif_skipped and exits 0; Grafi then runs in pure Elixir
# and Louvain/Leiden return {:error, :nif_not_available}.
#
# Environment:
#   IGRAPH_DIR=/prefix   use only this igraph install (include/, lib/, and
#                        lib/pkgconfig for the version when present); the
#                        only igraph a cross build (MIX_TARGET other than
#                        host, or a CXX for another OS) will use
#   IGRAPH_STATIC=1      link libigraph.a and its dependencies (release builds;
#                        needs igraph.pc); 0 or unset links dynamically
#   GRAFI_REQUIRE_NIF=1  fail instead of skipping when igraph is unusable
#   FINE_INCLUDE_DIR     fine's C++ headers; set by mix.exs (make_env)
#   ERTS_INCLUDE_DIR     erl_nif.h; set by elixir_make
#
# Install igraph: `brew install igraph` on macOS, or build the 1.0.1 release
# from https://github.com/igraph/igraph/releases (distro packages are often 0.10).

PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO   = $(PRIV_DIR)/grafi_nif.so
SKIPPED  = $(PRIV_DIR)/.grafi_nif_skipped
STAMP    = $(PRIV_DIR)/.igraph_version
comma   := ,
# A literal '#' for $(shell ...) commands; `\#` inside $(shell) differs
# between make 3.81 (macOS) and make >= 4.3.
HASH    := \#

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s erlang halt)

# IGRAPH_STATIC=1/true/yes turns static linking on; unset, 0 or anything
# else leaves it off.
STATIC := $(filter 1 true yes,$(IGRAPH_STATIC))

# The OS being built for: cc_precompiler names the target when it
# (cross-)compiles for one; otherwise ask the compiler (cross toolchains
# such as Nerves set CXX), and fall back to the host.
HOST_OS := $(shell uname -s)
CXX_MACHINE := $(shell $(CXX) -dumpmachine 2>/dev/null)
ifneq ($(findstring darwin,$(CC_PRECOMPILER_CURRENT_TARGET)),)
  TARGET_OS := Darwin
else ifneq ($(CC_PRECOMPILER_CURRENT_TARGET),)
  TARGET_OS := Linux
else ifneq ($(findstring darwin,$(CXX_MACHINE)),)
  TARGET_OS := Darwin
else ifneq ($(CXX_MACHINE),)
  TARGET_OS := Linux
else
  TARGET_OS := $(HOST_OS)
endif

# A native build may use the host's igraph (pkg-config, Homebrew,
# /usr/local); a cross build only an explicit IGRAPH_DIR.
NATIVE := $(and $(filter $(TARGET_OS),$(HOST_OS)),$(filter host,$(or $(MIX_TARGET),host)))

# ── igraph detection ──────────────────────────────────────────────────
# With IGRAPH_DIR, pkg-config may only look inside that prefix. A relative
# IGRAPH_DIR would end up as a CWD-relative rpath, so make it absolute.
ifdef IGRAPH_DIR
  override IGRAPH_DIR := $(abspath $(IGRAPH_DIR))
  PC := PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=$(IGRAPH_DIR)/lib/pkgconfig pkg-config
else ifneq ($(NATIVE),)
  PC := pkg-config
else
  # Cross build without IGRAPH_DIR: the host's pkg-config describes the
  # wrong architecture.
  PC := false
endif

IGRAPH_PC := $(shell $(PC) --exists igraph 2>/dev/null && echo 1)

ifeq ($(IGRAPH_PC),1)
  IGRAPH_VERSION := $(shell $(PC) --modversion igraph)
  IGRAPH_CFLAGS  := $(shell $(PC) --cflags igraph)
  IGRAPH_LIBDIR  := $(shell $(PC) --variable=libdir igraph)
  ifneq ($(STATIC),)
    # The archive itself, never the shared library, plus its private deps.
    IGRAPH_LIBFILE := $(wildcard $(IGRAPH_LIBDIR)/libigraph.a)
    IGRAPH_LIBS    := $(IGRAPH_LIBDIR)/libigraph.a $(filter-out -ligraph -L%,$(shell $(PC) --static --libs igraph))
  else
    IGRAPH_LIBFILE := $(firstword $(wildcard $(IGRAPH_LIBDIR)/libigraph.so* $(IGRAPH_LIBDIR)/libigraph.dylib $(IGRAPH_LIBDIR)/libigraph.a))
    IGRAPH_LIBS    := $(shell $(PC) --libs igraph)
  endif
else
  # No igraph.pc: look for headers and library under a prefix; read the
  # version from igraph_version.h. Homebrew on Apple Silicon installs to
  # /opt/homebrew, so ask brew before falling back to /usr/local (only for
  # native macOS builds).
  ifdef IGRAPH_DIR
    IGRAPH_PREFIX := $(IGRAPH_DIR)
  else ifeq ($(TARGET_OS):$(NATIVE),Darwin:host)
    IGRAPH_PREFIX := $(or $(shell brew --prefix --installed igraph 2>/dev/null),/usr/local)
  else ifneq ($(NATIVE),)
    IGRAPH_PREFIX := /usr/local
  else
    # Cross build without IGRAPH_DIR: never link the host's igraph.
    IGRAPH_PREFIX := /nonexistent-igraph-for-cross-builds
  endif
  IGRAPH_VERSION := $(shell sed -n 's/^$(HASH)define IGRAPH_VERSION "\([^"]*\)".*/\1/p' $(IGRAPH_PREFIX)/include/igraph/igraph_version.h 2>/dev/null)
  IGRAPH_CFLAGS  := -I$(IGRAPH_PREFIX)/include/igraph
  IGRAPH_LIBFILE := $(firstword $(wildcard $(IGRAPH_PREFIX)/lib/libigraph.* $(IGRAPH_PREFIX)/lib64/libigraph.*))
  IGRAPH_LIBDIR  := $(patsubst %/,%,$(dir $(IGRAPH_LIBFILE)))
  IGRAPH_LIBS    := -L$(IGRAPH_LIBDIR) -ligraph
  ifneq ($(STATIC),)
    IGRAPH_NEEDS_PC := 1
  endif
endif

IGRAPH_MAJOR  := $(firstword $(subst ., ,$(IGRAPH_VERSION)))
IGRAPH_INCDIR := $(patsubst -I%,%,$(firstword $(filter -I%,$(IGRAPH_CFLAGS))))
# The NIF installs igraph error handlers per thread; that needs an igraph
# built with thread-local storage (IGRAPH_ENABLE_TLS).
IGRAPH_TLS    := $(shell grep -q '^$(HASH)define IGRAPH_THREAD_SAFE 1' $(IGRAPH_INCDIR)/igraph_threading.h 2>/dev/null && echo 1)

ifeq ($(IGRAPH_VERSION),)
  IGRAPH_PROBLEM := igraph >= 1.0 not found
else ifneq ($(shell test "$(IGRAPH_MAJOR)" -ge 1 2>/dev/null && echo 1),1)
  IGRAPH_PROBLEM := igraph $(IGRAPH_VERSION) found in $(or $(IGRAPH_LIBDIR),$(IGRAPH_PREFIX)), but >= 1.0 is required
else ifeq ($(IGRAPH_NEEDS_PC),1)
  IGRAPH_PROBLEM := IGRAPH_STATIC=1 needs igraph.pc to find igraph's private libraries
else ifeq ($(IGRAPH_LIBFILE),)
  IGRAPH_PROBLEM := igraph $(IGRAPH_VERSION) headers found, but no $(if $(STATIC),libigraph.a,libigraph) next to them
else ifneq ($(IGRAPH_TLS),1)
  IGRAPH_PROBLEM := igraph $(IGRAPH_VERSION) was built without thread safety (IGRAPH_ENABLE_TLS), which the NIF needs
endif

# ── Compiler and linker flags ─────────────────────────────────────────
CXXFLAGS  = -std=c++17 -O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter
# Hardening. No -Werror, so newer toolchains don't break end-user installs
# over benign warnings; CI can layer that on. _FORTIFY_SOURCE is reset first
# so a toolchain default is not redefined; glibc < 2.34 treats 3 as 2.
CXXFLAGS += -fvisibility=hidden -fno-strict-aliasing -fstack-protector-strong
CXXFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3
CXXFLAGS += -I$(ERTS_INCLUDE_DIR) -I$(FINE_INCLUDE_DIR) $(IGRAPH_CFLAGS)

# Export only nif_init: our code is -fvisibility=hidden, but weak C++
# template instantiations and a static libigraph.a are not.
ifeq ($(TARGET_OS),Darwin)
  # erl_nif symbols resolve against the loading VM.
  LDFLAGS_EXTRA = -undefined dynamic_lookup -Wl,-exported_symbol,_nif_init
else
  LDFLAGS_EXTRA = -Wl,-z,relro,-z,now -Wl,--exclude-libs,ALL \
                  -Wl,--version-script=$(CURDIR)/c_src/grafi_nif.map
endif

# A shared libigraph needs an rpath so the NIF finds it without
# LD_LIBRARY_PATH. (Homebrew's dylibs carry absolute install names, so on
# macOS this rarely matters.)
ifeq ($(STATIC),)
  LDFLAGS_EXTRA += $(if $(IGRAPH_LIBDIR),-Wl$(comma)-rpath$(comma)$(IGRAPH_LIBDIR))
endif

SOURCES = c_src/grafi_nif.cpp
HEADERS = c_src/grafi_nif.h c_src/grafi_nif.map \
          $(wildcard $(FINE_INCLUDE_DIR)/fine.hpp $(FINE_INCLUDE_DIR)/fine/*.hpp)

# Rebuild when the igraph install, the link mode or the ERTS headers change,
# not only when the sources do. The stamp is rewritten only when its content
# changes.
STAMP_CONTENT = $(IGRAPH_VERSION) $(IGRAPH_LIBDIR) static=$(STATIC) target=$(TARGET_OS) erts=$(ERTS_INCLUDE_DIR)

.PHONY: all clean FORCE
.DELETE_ON_ERROR:

ifeq ($(IGRAPH_PROBLEM),)

all: $(NIF_SO)

$(STAMP): FORCE
	@mkdir -p $(PRIV_DIR)
	@echo '$(STAMP_CONTENT)' | cmp -s - $@ || echo '$(STAMP_CONTENT)' > $@

$(NIF_SO): $(SOURCES) $(HEADERS) $(STAMP)
	@test -n "$(FINE_INCLUDE_DIR)" || { echo "grafi: FINE_INCLUDE_DIR is not set; build through mix" >&2; exit 1; }
	@echo "grafi: using igraph $(IGRAPH_VERSION) from $(IGRAPH_LIBDIR)$(if $(STATIC), (static))"
	$(CXX) $(CXXFLAGS) -o $@ $(SOURCES) $(IGRAPH_LIBS) $(LDFLAGS_EXTRA)
	@rm -f $(SKIPPED)

else

all:
ifeq ($(GRAFI_REQUIRE_NIF),1)
	@echo "grafi: $(IGRAPH_PROBLEM), and GRAFI_REQUIRE_NIF=1" >&2
	@exit 1
else
	@echo "grafi: $(IGRAPH_PROBLEM); building without NIF (pure Elixir)"
	@mkdir -p $(PRIV_DIR)
	@rm -f $(NIF_SO) $(STAMP)
	@touch $(SKIPPED)
endif

endif

clean:
	rm -f $(NIF_SO) $(SKIPPED) $(STAMP)

FORCE:
