// c_src/grafi_nif.h
// Grafi NIF — igraph bridge via fine
//
// This header defines the conversion layer between Elixir graph
// representation (CSR arrays) and igraph's internal format.

#pragma once

#include <igraph.h>
#include <vector>
#include <cstdint>
#include <string>

namespace grafi {

// ── Graph conversion ───────────────────────────────────────────────────
//
// Elixir sends graphs as CSR (Compressed Sparse Row):
//   row_offsets: [int64]  — length n_vertices + 1
//   col_indices: [int64]  — length n_edges
//   weights:     [double] — length n_edges
//   n_vertices:  int64
//   directed:    bool

struct CsrGraph {
    std::vector<int64_t> row_offsets;
    std::vector<int64_t> col_indices;
    std::vector<double>  weights;
    int64_t              n_vertices;
    bool                 directed;
};

// Build an igraph_t from CSR data. Caller must destroy with igraph_destroy().
// Throws std::runtime_error on igraph failure.
igraph_t csr_to_igraph(const CsrGraph& csr);

// Build an igraph weight vector. Caller must destroy with igraph_vector_destroy().
igraph_vector_t csr_to_weights(const CsrGraph& csr);

// Validate the structural invariants of a CSR map. Throws std::invalid_argument
// on the first violation. Call immediately after decode_csr.
//   - row_offsets.size() == n_vertices + 1
//   - row_offsets[0] == 0 and monotonic non-decreasing
//   - row_offsets[n_vertices] == col_indices.size()
//   - col_indices.size() == weights.size()
//   - col_indices[j] in [0, n_vertices)
//   - n_vertices >= 0
void validate_csr_structure(const CsrGraph& csr);

// ── Algorithm result types ─────────────────────────────────────────────

struct PageRankResult {
    std::vector<double> ranks;
};

struct ShortestPathResult {
    std::vector<int64_t> path;      // vertex indices along path
    double               distance;
    bool                 found;
};

struct CommunityResult {
    std::vector<int64_t> membership; // community id per vertex
    double               modularity;
    int64_t              n_communities;
};

struct CentralityResult {
    std::vector<double> scores;
};

struct SccResult {
    std::vector<int64_t> membership;
    int64_t              n_components;
};

struct IsomorphismResult {
    bool                  iso;       // true if (sub)isomorphism found
    std::vector<int64_t>  mapping;   // map12: index = vertex in g1, value = vertex in g2.
                                     // Empty when iso == false.
};

// ── Algorithm wrappers ─────────────────────────────────────────────────

PageRankResult     compute_pagerank(const CsrGraph& g, double damping, int max_iter);
ShortestPathResult compute_dijkstra(const CsrGraph& g, int64_t source, int64_t target);
// TODO: wire up a `nif_bellman_ford` NIF (Elixir falls back to a pure-Elixir
// implementation in `lib/grafi/algo/shortest_path.ex` today). igraph provides
// `igraph_get_shortest_path_bellman_ford` which would be a straight port of
// `compute_dijkstra` with negative-weight support and negative-cycle reporting.
CentralityResult   compute_betweenness(const CsrGraph& g);
CentralityResult   compute_closeness(const CsrGraph& g);
CommunityResult    compute_louvain(const CsrGraph& g);
CommunityResult    compute_label_propagation(const CsrGraph& g);
CommunityResult    compute_leiden(const CsrGraph& g, double resolution);
SccResult          compute_scc(const CsrGraph& g);
bool               compute_is_acyclic(const CsrGraph& g);
std::vector<int64_t> compute_topological_sort(const CsrGraph& g);

// VF2 (sub)graph isomorphism — wrappers around igraph's VF2 implementation.
//
// `compute_isomorphic_vf2` returns only the boolean iso flag (and an empty
// mapping). `compute_isomorphism_vf2` additionally returns one witness mapping
// when iso == true. Same convention for the sub-isomorphism variants:
// `g1` is the *host* graph, `g2` is the *pattern*.
bool                 compute_isomorphic_vf2(const CsrGraph& g1, const CsrGraph& g2);
bool                 compute_subisomorphic_vf2(const CsrGraph& g1, const CsrGraph& g2);
IsomorphismResult    compute_isomorphism_vf2(const CsrGraph& g1, const CsrGraph& g2);
IsomorphismResult    compute_subgraph_isomorphism_vf2(const CsrGraph& g1, const CsrGraph& g2);
int64_t              compute_count_subisomorphisms_vf2(const CsrGraph& g1, const CsrGraph& g2);

} // namespace grafi
