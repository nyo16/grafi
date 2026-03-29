# Makefile for Grafi NIF — wraps igraph via fine (C++)
#
# Expects igraph to be installed system-wide or via IGRAPH_DIR.
# On macOS: brew install igraph
# On Ubuntu: apt install libigraph-dev
# Or build from source: https://igraph.org/c/doc/igraph-Installation.html

PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO   = $(PRIV_DIR)/grafi_nif.so

FINE_INCLUDE = $(shell elixir -e 'IO.puts Fine.include_dir()' 2>/dev/null || echo "")
ERTS_INCLUDE = $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s erlang halt)

# igraph detection
IGRAPH_DIR    ?= $(shell pkg-config --variable=prefix igraph 2>/dev/null || echo "/usr/local")
IGRAPH_CFLAGS  = $(shell pkg-config --cflags igraph 2>/dev/null || echo "-I$(IGRAPH_DIR)/include")
IGRAPH_LDFLAGS = $(shell pkg-config --libs igraph 2>/dev/null || echo "-L$(IGRAPH_DIR)/lib -ligraph")

CXX      ?= c++
CXXFLAGS  = -std=c++17 -O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter
CXXFLAGS += -I$(ERTS_INCLUDE) $(IGRAPH_CFLAGS)

ifneq ($(FINE_INCLUDE),)
CXXFLAGS += -I$(FINE_INCLUDE)
endif

# macOS-specific
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  CXXFLAGS += -undefined dynamic_lookup -flat_namespace
endif

SOURCES = c_src/grafi_nif.cpp
HEADERS = c_src/grafi_nif.h

.PHONY: all clean

all: $(NIF_SO)

$(NIF_SO): $(SOURCES) $(HEADERS)
	@mkdir -p $(PRIV_DIR)
	$(CXX) $(CXXFLAGS) -o $@ $(SOURCES) $(IGRAPH_LDFLAGS)

clean:
	rm -f $(NIF_SO)
