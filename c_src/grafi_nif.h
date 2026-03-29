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
igraph_t csr_to_igraph(const CsrGraph& csr);

// Build an igraph weight vector. Caller must destroy with igraph_vector_destroy().
igraph_vector_t csr_to_weights(const CsrGraph& csr);

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

// ── Algorithm wrappers ─────────────────────────────────────────────────

PageRankResult     compute_pagerank(const CsrGraph& g, double damping, int max_iter);
ShortestPathResult compute_dijkstra(const CsrGraph& g, int64_t source, int64_t target);
ShortestPathResult compute_bellman_ford(const CsrGraph& g, int64_t source, int64_t target);
CentralityResult   compute_betweenness(const CsrGraph& g);
CentralityResult   compute_closeness(const CsrGraph& g);
CommunityResult    compute_louvain(const CsrGraph& g);
CommunityResult    compute_label_propagation(const CsrGraph& g);
CommunityResult    compute_leiden(const CsrGraph& g, double resolution);
SccResult          compute_scc(const CsrGraph& g);
bool               compute_is_acyclic(const CsrGraph& g);
std::vector<int64_t> compute_topological_sort(const CsrGraph& g);

} // namespace grafi
