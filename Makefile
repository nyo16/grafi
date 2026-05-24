# Makefile for Grafi NIF — wraps igraph via fine (C++)
#
# Expects igraph >= 1.0.0 to be installed system-wide or via IGRAPH_DIR.
# On macOS: brew install igraph
# On Ubuntu: apt install libigraph-dev   (note: distro pkg may be < 1.0)
# Or build from source: https://igraph.org/c/doc/igraph-Installation.html

PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO   = $(PRIV_DIR)/grafi_nif.so

FINE_INCLUDE = $(shell elixir -e 'IO.puts Fine.include_dir()' 2>/dev/null || echo "$(CURDIR)/deps/fine/c_include")
ERTS_INCLUDE = $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s erlang halt)

# ── igraph detection ──────────────────────────────────────────────────
IGRAPH_DIR     ?= $(shell pkg-config --variable=prefix igraph 2>/dev/null || echo "/usr/local")
IGRAPH_CFLAGS   = $(shell pkg-config --cflags igraph 2>/dev/null || echo "-I$(IGRAPH_DIR)/include")
IGRAPH_LDFLAGS  = $(shell pkg-config --libs igraph 2>/dev/null || echo "-L$(IGRAPH_DIR)/lib -ligraph")
IGRAPH_LIBDIR   = $(shell pkg-config --variable=libdir igraph 2>/dev/null || echo "$(IGRAPH_DIR)/lib")
IGRAPH_VERSION  = $(shell pkg-config --modversion igraph 2>/dev/null)

# Abort early if pkg-config found igraph < 1.0.0. If pkg-config didn't find
# igraph (IGRAPH_VERSION empty), we can't check — silently allow it and rely
# on link-time failures or runtime symbol errors.
# TODO: add a non-pkg-config version probe (parse igraph_version.h) for
# environments without pkg-config.
IGRAPH_VERSION_OK := $(shell test -z "$(IGRAPH_VERSION)" || \
    awk -v v="$(IGRAPH_VERSION)" 'BEGIN { split(v, p, "."); print (p[1]+0 >= 1) ? "1" : "0"; exit }')

CXX      ?= c++
CXXFLAGS  = -std=c++17 -O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter
# Hardening flags. We deliberately do NOT add -Werror so newer toolchains
# don't break end-user installs over benign warnings; CI can layer that on.
CXXFLAGS += -fvisibility=hidden -fno-strict-aliasing -D_FORTIFY_SOURCE=2
CXXFLAGS += -I$(ERTS_INCLUDE) $(IGRAPH_CFLAGS)

ifneq ($(FINE_INCLUDE),)
CXXFLAGS += -I$(FINE_INCLUDE)
endif

# Embed an rpath to the igraph lib dir so the loaded NIF can find
# libigraph at runtime without LD_LIBRARY_PATH gymnastics. Only emitted
# if we actually detected a sensible libdir.
ifneq ($(strip $(IGRAPH_LIBDIR)),)
LDFLAGS_RPATH = -Wl,-rpath,$(IGRAPH_LIBDIR)
else
LDFLAGS_RPATH =
endif

# macOS-specific
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  CXXFLAGS += -undefined dynamic_lookup -flat_namespace
endif

SOURCES = c_src/grafi_nif.cpp
HEADERS = c_src/grafi_nif.h

.PHONY: all clean check-igraph-version

all: check-igraph-version $(NIF_SO)

check-igraph-version:
	@if [ -n "$(IGRAPH_VERSION)" ] && [ "$(IGRAPH_VERSION_OK)" != "1" ]; then \
	    echo "ERROR: igraph $(IGRAPH_VERSION) detected, Grafi requires igraph >= 1.0.0"; \
	    echo "       Install a newer igraph or set IGRAPH_DIR=/path/to/igraph-1.x"; \
	    exit 1; \
	fi
	@if [ -n "$(IGRAPH_VERSION)" ]; then \
	    echo "Using igraph $(IGRAPH_VERSION) from $(IGRAPH_LIBDIR)"; \
	fi

$(NIF_SO): $(SOURCES) $(HEADERS)
	@mkdir -p $(PRIV_DIR)
	$(CXX) $(CXXFLAGS) -o $@ $(SOURCES) $(IGRAPH_LDFLAGS) $(LDFLAGS_RPATH)

clean:
	rm -f $(NIF_SO)
