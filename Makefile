# Makefile for the Grafi NIF: C++ (via fine) wrapping igraph >= 1.0.
#
# igraph is optional. When it is missing (or older than 1.0) the build prints
# a notice, writes $(PRIV_DIR)/.grafi_nif_skipped and exits 0; Grafi then runs
# in pure Elixir and Louvain/Leiden return {:error, :nif_not_available}.
#
# Environment:
#   IGRAPH_DIR=/prefix   use only this igraph install (include/, lib/, and
#                        lib/pkgconfig for the version when present)
#   IGRAPH_STATIC=1      link libigraph.a and its dependencies (release builds)
#   GRAFI_REQUIRE_NIF=1  fail instead of skipping when igraph >= 1.0 is missing
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

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s erlang halt)

UNAME_S := $(shell uname -s)

# ── igraph detection ──────────────────────────────────────────────────
# With IGRAPH_DIR, pkg-config may only look inside that prefix.
ifdef IGRAPH_DIR
  PC := PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=$(IGRAPH_DIR)/lib/pkgconfig pkg-config
else
  PC := pkg-config
endif

IGRAPH_PC := $(shell $(PC) --exists igraph 2>/dev/null && echo 1)

ifeq ($(IGRAPH_PC),1)
  IGRAPH_VERSION := $(shell $(PC) --modversion igraph)
  IGRAPH_CFLAGS  := $(shell $(PC) --cflags igraph)
  IGRAPH_LIBDIR  := $(shell $(PC) --variable=libdir igraph)
  IGRAPH_LIBS    := $(shell $(PC) $(if $(IGRAPH_STATIC),--static) --libs igraph)
else
  # No igraph.pc: look for the headers directly and read the version from
  # igraph_version.h.
  IGRAPH_PREFIX  := $(or $(IGRAPH_DIR),/usr/local)
  IGRAPH_VERSION := $(shell sed -n 's/^\#define IGRAPH_VERSION "\([^"]*\)".*/\1/p' $(IGRAPH_PREFIX)/include/igraph/igraph_version.h 2>/dev/null)
  IGRAPH_CFLAGS  := -I$(IGRAPH_PREFIX)/include/igraph
  IGRAPH_LIBDIR  := $(IGRAPH_PREFIX)/lib
  IGRAPH_LIBS    := -L$(IGRAPH_LIBDIR) -ligraph
endif

IGRAPH_MAJOR := $(firstword $(subst ., ,$(IGRAPH_VERSION)))
IGRAPH_OK    := $(shell test -n "$(IGRAPH_MAJOR)" && test "$(IGRAPH_MAJOR)" -ge 1 2>/dev/null && echo 1)

ifeq ($(IGRAPH_VERSION),)
  IGRAPH_MISSING := igraph >= 1.0 not found
else
  IGRAPH_MISSING := igraph $(IGRAPH_VERSION) found in $(IGRAPH_LIBDIR), but >= 1.0 is required
endif

# ── Compiler and linker flags ─────────────────────────────────────────
CXX      ?= c++
CXXFLAGS  = -std=c++17 -O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter
# Hardening. No -Werror, so newer toolchains don't break end-user installs
# over benign warnings; CI can layer that on.
CXXFLAGS += -fvisibility=hidden -fno-strict-aliasing -D_FORTIFY_SOURCE=2
CXXFLAGS += -fstack-protector-strong
CXXFLAGS += -I$(ERTS_INCLUDE_DIR) -I$(FINE_INCLUDE_DIR) $(IGRAPH_CFLAGS)

# Export only nif_init. Our code is already -fvisibility=hidden, but a static
# libigraph.a (IGRAPH_STATIC=1) is not, and its symbols would leak.
ifeq ($(UNAME_S),Darwin)
  # erl_nif symbols resolve against the loading VM.
  LDFLAGS_EXTRA = -undefined dynamic_lookup -Wl,-exported_symbol,_nif_init
else
  LDFLAGS_EXTRA = -Wl,-z,relro,-z,now -Wl,--exclude-libs,ALL
endif

# A shared libigraph needs an rpath so the NIF finds it without
# LD_LIBRARY_PATH. On macOS prefer Homebrew's stable `opt` path over the
# versioned Cellar path, so `brew upgrade igraph` doesn't break the NIF.
ifeq ($(IGRAPH_STATIC),)
  IGRAPH_RPATH := $(IGRAPH_LIBDIR)
  ifeq ($(UNAME_S),Darwin)
    ifndef IGRAPH_DIR
      BREW_IGRAPH_LIB := $(shell brew --prefix igraph 2>/dev/null)/lib
      ifeq ($(shell cd $(BREW_IGRAPH_LIB) 2>/dev/null && pwd -P),$(shell cd $(IGRAPH_LIBDIR) 2>/dev/null && pwd -P))
        IGRAPH_RPATH := $(BREW_IGRAPH_LIB)
      endif
    endif
  endif
  LDFLAGS_EXTRA += $(if $(strip $(IGRAPH_RPATH)),-Wl$(comma)-rpath$(comma)$(IGRAPH_RPATH))
endif

SOURCES = c_src/grafi_nif.cpp
HEADERS = c_src/grafi_nif.h

# Rebuild when the igraph install or link mode changes, not only when the
# sources do. The stamp is rewritten only when its content changes.
STAMP_CONTENT = $(IGRAPH_VERSION) $(IGRAPH_LIBDIR) static=$(IGRAPH_STATIC)

.PHONY: all clean FORCE

ifeq ($(IGRAPH_OK),1)

all: $(NIF_SO)

$(STAMP): FORCE
	@mkdir -p $(PRIV_DIR)
	@echo '$(STAMP_CONTENT)' | cmp -s - $@ || echo '$(STAMP_CONTENT)' > $@

$(NIF_SO): $(SOURCES) $(HEADERS) $(STAMP)
	@test -n "$(FINE_INCLUDE_DIR)" || { echo "grafi: FINE_INCLUDE_DIR is not set; build through mix" >&2; exit 1; }
	@echo "grafi: using igraph $(IGRAPH_VERSION) from $(IGRAPH_LIBDIR)$(if $(IGRAPH_STATIC), (static))"
	$(CXX) $(CXXFLAGS) -o $@ $(SOURCES) $(IGRAPH_LIBS) $(LDFLAGS_EXTRA)
	@rm -f $(SKIPPED)

else

all:
ifeq ($(GRAFI_REQUIRE_NIF),1)
	@echo "grafi: $(IGRAPH_MISSING), and GRAFI_REQUIRE_NIF=1" >&2
	@exit 1
else
	@echo "grafi: $(IGRAPH_MISSING); building without NIF (pure Elixir)"
	@mkdir -p $(PRIV_DIR)
	@rm -f $(NIF_SO) $(STAMP)
	@touch $(SKIPPED)
endif

endif

clean:
	rm -f $(NIF_SO) $(SKIPPED) $(STAMP)

FORCE:
