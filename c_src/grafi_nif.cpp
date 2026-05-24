// c_src/grafi_nif.cpp
// Grafi NIF — high-performance graph algorithms via igraph + fine
//
// Each NIF receives the graph in CSR format from Elixir, converts to
// igraph_t, runs the algorithm, and returns results as Elixir terms.
// All NIFs are scheduled on dirty CPU schedulers via fine.
//
// Compatible with igraph >= 1.0.0
//
// ─── TODO for Agent 2 (lib/grafi/nif.ex) ───────────────────────────────
// No new NIF arities/registrations were added in this pass. The dead
// `compute_bellman_ford` declaration was removed from grafi_nif.h; if
// you want a `nif_bellman_ford/3` later, see the TODO in grafi_nif.h.
// ───────────────────────────────────────────────────────────────────────

#include "grafi_nif.h"
#include <fine.hpp>
#include <stdexcept>
#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <cstring>

namespace grafi {

// ═══════════════════════════════════════════════════════════════════════
// RAII guards for igraph allocations
//
// Each guard owns one igraph object and destroys it on scope exit, even
// on exception. The explicit `init()` overloads are kept thin so call
// sites read naturally; failures from igraph_*_init are surfaced via the
// `igraph_error_t` return value (we throw on non-success).
// ═══════════════════════════════════════════════════════════════════════

static void check_igraph(igraph_error_t err, const char* what) {
    if (err != IGRAPH_SUCCESS) {
        std::string msg = "igraph error in ";
        msg += what;
        msg += ": ";
        msg += igraph_strerror(err);
        throw std::runtime_error(msg);
    }
}

struct IgraphGraph {
    igraph_t g;
    bool owns = false;
    IgraphGraph() = default;
    IgraphGraph(const IgraphGraph&) = delete;
    IgraphGraph& operator=(const IgraphGraph&) = delete;
    IgraphGraph(IgraphGraph&& other) noexcept : g(other.g), owns(other.owns) {
        other.owns = false;
    }
    IgraphGraph& operator=(IgraphGraph&& other) noexcept {
        if (this != &other) {
            if (owns) igraph_destroy(&g);
            g = other.g;
            owns = other.owns;
            other.owns = false;
        }
        return *this;
    }
    ~IgraphGraph() { if (owns) igraph_destroy(&g); }
    igraph_t* ptr() { return &g; }
    const igraph_t* ptr() const { return &g; }
    void mark_owned() { owns = true; }
};

struct IgraphVector {
    igraph_vector_t v;
    bool owns = false;
    IgraphVector() = default;
    explicit IgraphVector(igraph_integer_t size) {
        check_igraph(igraph_vector_init(&v, size), "igraph_vector_init");
        owns = true;
    }
    IgraphVector(const IgraphVector&) = delete;
    IgraphVector& operator=(const IgraphVector&) = delete;
    IgraphVector(IgraphVector&& other) noexcept : v(other.v), owns(other.owns) {
        other.owns = false;
    }
    IgraphVector& operator=(IgraphVector&& other) noexcept {
        if (this != &other) {
            if (owns) igraph_vector_destroy(&v);
            v = other.v;
            owns = other.owns;
            other.owns = false;
        }
        return *this;
    }
    ~IgraphVector() { if (owns) igraph_vector_destroy(&v); }
    igraph_vector_t* ptr() { return &v; }
    const igraph_vector_t* ptr() const { return &v; }
};

struct IgraphVectorInt {
    igraph_vector_int_t v;
    bool owns = false;
    IgraphVectorInt() = default;
    explicit IgraphVectorInt(igraph_integer_t size) {
        check_igraph(igraph_vector_int_init(&v, size), "igraph_vector_int_init");
        owns = true;
    }
    IgraphVectorInt(const IgraphVectorInt&) = delete;
    IgraphVectorInt& operator=(const IgraphVectorInt&) = delete;
    IgraphVectorInt(IgraphVectorInt&& other) noexcept : v(other.v), owns(other.owns) {
        other.owns = false;
    }
    IgraphVectorInt& operator=(IgraphVectorInt&& other) noexcept {
        if (this != &other) {
            if (owns) igraph_vector_int_destroy(&v);
            v = other.v;
            owns = other.owns;
            other.owns = false;
        }
        return *this;
    }
    ~IgraphVectorInt() { if (owns) igraph_vector_int_destroy(&v); }
    igraph_vector_int_t* ptr() { return &v; }
    const igraph_vector_int_t* ptr() const { return &v; }
};

struct IgraphVectorIntList {
    igraph_vector_int_list_t v;
    bool owns = false;
    IgraphVectorIntList() {
        check_igraph(igraph_vector_int_list_init(&v, 0), "igraph_vector_int_list_init");
        owns = true;
    }
    IgraphVectorIntList(const IgraphVectorIntList&) = delete;
    IgraphVectorIntList& operator=(const IgraphVectorIntList&) = delete;
    IgraphVectorIntList(IgraphVectorIntList&& other) noexcept
        : v(other.v), owns(other.owns) {
        other.owns = false;
    }
    IgraphVectorIntList& operator=(IgraphVectorIntList&& other) noexcept {
        if (this != &other) {
            if (owns) igraph_vector_int_list_destroy(&v);
            v = other.v;
            owns = other.owns;
            other.owns = false;
        }
        return *this;
    }
    ~IgraphVectorIntList() { if (owns) igraph_vector_int_list_destroy(&v); }
    igraph_vector_int_list_t* ptr() { return &v; }
    const igraph_vector_int_list_t* ptr() const { return &v; }
};

// ═══════════════════════════════════════════════════════════════════════
// Graph conversion
// ═══════════════════════════════════════════════════════════════════════

void validate_csr_structure(const CsrGraph& csr) {
    if (csr.n_vertices < 0) {
        throw std::invalid_argument("CSR n_vertices is negative");
    }
    const size_t n = static_cast<size_t>(csr.n_vertices);

    if (csr.row_offsets.size() != n + 1) {
        throw std::invalid_argument("CSR row_offsets length must equal n_vertices + 1");
    }
    // row_offsets.size() is now guaranteed >= 1 (since n+1 >= 1).
    if (csr.row_offsets[0] != 0) {
        throw std::invalid_argument("CSR row_offsets[0] must be 0");
    }
    for (size_t i = 0; i + 1 < csr.row_offsets.size(); i++) {
        if (csr.row_offsets[i] > csr.row_offsets[i + 1]) {
            throw std::invalid_argument("CSR row_offsets must be monotonic non-decreasing");
        }
    }
    if (csr.col_indices.size() != csr.weights.size()) {
        throw std::invalid_argument("CSR col_indices and weights must have same length");
    }
    if (static_cast<int64_t>(csr.col_indices.size()) != csr.row_offsets[n]) {
        throw std::invalid_argument("CSR row_offsets[n_vertices] must equal col_indices length");
    }
    for (size_t j = 0; j < csr.col_indices.size(); j++) {
        int64_t c = csr.col_indices[j];
        if (c < 0 || c >= csr.n_vertices) {
            throw std::invalid_argument("CSR col_indices contains out-of-range vertex id");
        }
    }
    for (size_t j = 0; j < csr.weights.size(); j++) {
        double w = csr.weights[j];
        if (std::isnan(w) || std::isinf(w)) {
            throw std::invalid_argument("CSR weights contain NaN or Inf");
        }
    }
}

igraph_t csr_to_igraph(const CsrGraph& csr) {
    IgraphVectorInt edges(0);

    // Convert CSR to edge list
    for (int64_t row = 0; row < csr.n_vertices; row++) {
        for (int64_t j = csr.row_offsets[row]; j < csr.row_offsets[row + 1]; j++) {
            check_igraph(igraph_vector_int_push_back(edges.ptr(), row),
                         "igraph_vector_int_push_back");
            check_igraph(igraph_vector_int_push_back(edges.ptr(), csr.col_indices[j]),
                         "igraph_vector_int_push_back");
        }
    }

    igraph_t graph;
    check_igraph(igraph_create(&graph, edges.ptr(), csr.n_vertices,
                               csr.directed ? IGRAPH_DIRECTED : IGRAPH_UNDIRECTED),
                 "igraph_create");
    return graph;
}

igraph_vector_t csr_to_weights(const CsrGraph& csr) {
    igraph_vector_t weights;
    check_igraph(igraph_vector_init(&weights, csr.weights.size()),
                 "igraph_vector_init");
    for (size_t i = 0; i < csr.weights.size(); i++) {
        VECTOR(weights)[i] = csr.weights[i];
    }
    return weights;
}

// Builders that hand back an RAII guard with ownership transferred.
// These wrap the raw `csr_to_*` factories so call sites don't need the
// awkward "init-then-destroy-then-replace" dance.
static IgraphGraph build_graph_owned(const CsrGraph& csr) {
    IgraphGraph g;
    *g.ptr() = csr_to_igraph(csr);
    g.mark_owned();
    return g;
}

static void fill_weights(const CsrGraph& csr, IgraphVector& out) {
    // out is assumed default-constructed (owns == false); we initialise
    // here and mark ownership in one shot so an init failure can't leak.
    check_igraph(igraph_vector_init(out.ptr(), csr.weights.size()),
                 "igraph_vector_init");
    out.owns = true;
    for (size_t i = 0; i < csr.weights.size(); i++) {
        VECTOR(*out.ptr())[i] = csr.weights[i];
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Algorithm implementations (igraph 1.0.x API)
// ═══════════════════════════════════════════════════════════════════════

PageRankResult compute_pagerank(const CsrGraph& g, double damping, int /*max_iter*/) {
    // NOTE: `max_iter` is currently ignored because igraph 1.0.x's PRPACK
    // backend has no max-iteration knob (PRPACK runs to its own internal
    // convergence). It IS honoured by IGRAPH_PAGERANK_ALGO_ARPACK via
    // igraph_arpack_options_t.mxiter, but PRPACK is the recommended and
    // default algorithm. We keep `max_iter` in the NIF signature for
    // forward-compat with a future ARPACK opt-in.

    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVector result(0);
    igraph_real_t eigenvalue;

    check_igraph(igraph_pagerank(graph.ptr(), weights.ptr(),
                                 result.ptr(), &eigenvalue,
                                 damping,
                                 g.directed ? IGRAPH_DIRECTED : IGRAPH_UNDIRECTED,
                                 igraph_vss_all(),
                                 IGRAPH_PAGERANK_ALGO_PRPACK, NULL),
                 "igraph_pagerank");

    PageRankResult pr;
    pr.ranks.resize(igraph_vector_size(result.ptr()));
    for (igraph_integer_t i = 0; i < igraph_vector_size(result.ptr()); i++) {
        pr.ranks[i] = VECTOR(*result.ptr())[i];
    }
    return pr;
}

ShortestPathResult compute_dijkstra(const CsrGraph& g, int64_t source, int64_t target) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVectorIntList paths;

    IgraphVectorInt targets(1);
    VECTOR(*targets.ptr())[0] = target;

    check_igraph(igraph_get_shortest_paths_dijkstra(
                     graph.ptr(), paths.ptr(), NULL,
                     source, igraph_vss_vector(targets.ptr()),
                     weights.ptr(),
                     g.directed ? IGRAPH_OUT : IGRAPH_ALL,
                     NULL, NULL),
                 "igraph_get_shortest_paths_dijkstra");

    ShortestPathResult result;
    if (igraph_vector_int_list_size(paths.ptr()) > 0) {
        igraph_vector_int_t* path = igraph_vector_int_list_get_ptr(paths.ptr(), 0);
        igraph_integer_t path_len = igraph_vector_int_size(path);

        if (path_len > 0) {
            result.found = true;
            result.path.resize(path_len);
            result.distance = 0.0;

            for (igraph_integer_t i = 0; i < path_len; i++) {
                result.path[i] = VECTOR(*path)[i];
            }

            // Calculate total distance along path
            for (igraph_integer_t i = 0; i < path_len - 1; i++) {
                igraph_integer_t eid;
                igraph_get_eid(graph.ptr(), &eid, result.path[i], result.path[i + 1],
                               g.directed ? IGRAPH_DIRECTED : IGRAPH_UNDIRECTED, 0);
                if (eid >= 0) {
                    result.distance += VECTOR(*weights.ptr())[eid];
                }
            }
        } else {
            result.found = false;
            result.distance = IGRAPH_INFINITY;
        }
    } else {
        result.found = false;
        result.distance = IGRAPH_INFINITY;
    }
    return result;
}

CentralityResult compute_betweenness(const CsrGraph& g) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVector result(0);

    // igraph 1.0.x: weights 2nd arg, added normalized param
    check_igraph(igraph_betweenness(graph.ptr(), weights.ptr(), result.ptr(),
                                    igraph_vss_all(),
                                    g.directed ? IGRAPH_DIRECTED : IGRAPH_UNDIRECTED,
                                    false),
                 "igraph_betweenness");

    CentralityResult cr;
    cr.scores.resize(igraph_vector_size(result.ptr()));
    for (igraph_integer_t i = 0; i < igraph_vector_size(result.ptr()); i++) {
        cr.scores[i] = VECTOR(*result.ptr())[i];
    }
    return cr;
}

CentralityResult compute_closeness(const CsrGraph& g) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVector result(0);

    // Closeness mode mirrors graph directedness: IGRAPH_OUT for digraphs
    // (out-closeness, the conventional default), IGRAPH_ALL for undirected
    // graphs where it's the only meaningful choice.
    check_igraph(igraph_closeness(graph.ptr(), result.ptr(), NULL, NULL,
                                  igraph_vss_all(),
                                  g.directed ? IGRAPH_OUT : IGRAPH_ALL,
                                  weights.ptr(), true),
                 "igraph_closeness");

    CentralityResult cr;
    cr.scores.resize(igraph_vector_size(result.ptr()));
    for (igraph_integer_t i = 0; i < igraph_vector_size(result.ptr()); i++) {
        cr.scores[i] = VECTOR(*result.ptr())[i];
    }
    return cr;
}

CommunityResult compute_louvain(const CsrGraph& g) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVectorInt membership(0);
    IgraphVector modularity_vec(0);

    // igraph 1.0.x: modularity is now a vector (per-level), not a scalar
    check_igraph(igraph_community_multilevel(graph.ptr(), weights.ptr(),
                                             1.0, // resolution
                                             membership.ptr(), NULL,
                                             modularity_vec.ptr()),
                 "igraph_community_multilevel");

    CommunityResult cr;
    // Use the last (final) modularity value
    igraph_integer_t mod_len = igraph_vector_size(modularity_vec.ptr());
    cr.modularity = mod_len > 0 ? VECTOR(*modularity_vec.ptr())[mod_len - 1] : 0.0;

    cr.membership.resize(igraph_vector_int_size(membership.ptr()));
    int64_t max_id = 0;
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(membership.ptr()); i++) {
        cr.membership[i] = VECTOR(*membership.ptr())[i];
        if (cr.membership[i] > max_id) max_id = cr.membership[i];
    }
    cr.n_communities = cr.membership.empty() ? 0 : max_id + 1;
    return cr;
}

CommunityResult compute_label_propagation(const CsrGraph& g) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVectorInt membership(0);

    // igraph 1.0.x: 7 args including variant
    check_igraph(igraph_community_label_propagation(graph.ptr(), membership.ptr(),
                                                    IGRAPH_ALL, weights.ptr(),
                                                    NULL, NULL,
                                                    IGRAPH_LPA_FAST),
                 "igraph_community_label_propagation");

    CommunityResult cr;
    // Compute modularity separately
    igraph_real_t modularity;
    check_igraph(igraph_modularity(graph.ptr(), membership.ptr(), weights.ptr(),
                                   1.0,
                                   g.directed ? IGRAPH_DIRECTED : IGRAPH_UNDIRECTED,
                                   &modularity),
                 "igraph_modularity");
    cr.modularity = modularity;

    cr.membership.resize(igraph_vector_int_size(membership.ptr()));
    int64_t max_id = 0;
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(membership.ptr()); i++) {
        cr.membership[i] = VECTOR(*membership.ptr())[i];
        if (cr.membership[i] > max_id) max_id = cr.membership[i];
    }
    cr.n_communities = cr.membership.empty() ? 0 : max_id + 1;
    return cr;
}

CommunityResult compute_leiden(const CsrGraph& g, double resolution) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVectorInt membership(0);
    igraph_real_t quality;
    igraph_integer_t nb_clusters;

    // igraph 1.0.x: added vertex_out_weights and vertex_in_weights params
    check_igraph(igraph_community_leiden(graph.ptr(), weights.ptr(),
                                         NULL,  // vertex_out_weights
                                         NULL,  // vertex_in_weights
                                         resolution, 0.01, false,
                                         -1,
                                         membership.ptr(), &nb_clusters, &quality),
                 "igraph_community_leiden");

    CommunityResult cr;
    cr.modularity = quality;
    cr.n_communities = nb_clusters;
    cr.membership.resize(igraph_vector_int_size(membership.ptr()));
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(membership.ptr()); i++) {
        cr.membership[i] = VECTOR(*membership.ptr())[i];
    }
    return cr;
}

SccResult compute_scc(const CsrGraph& g) {
    IgraphGraph graph = build_graph_owned(g);

    IgraphVectorInt membership(0);
    igraph_integer_t n_comp;

    check_igraph(igraph_connected_components(graph.ptr(), membership.ptr(), NULL,
                                             &n_comp, IGRAPH_STRONG),
                 "igraph_connected_components");

    SccResult result;
    result.n_components = n_comp;
    result.membership.resize(igraph_vector_int_size(membership.ptr()));
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(membership.ptr()); i++) {
        result.membership[i] = VECTOR(*membership.ptr())[i];
    }
    return result;
}

bool compute_is_acyclic(const CsrGraph& g) {
    IgraphGraph graph = build_graph_owned(g);

    igraph_bool_t is_dag;
    check_igraph(igraph_is_dag(graph.ptr(), &is_dag), "igraph_is_dag");
    return is_dag;
}

std::vector<int64_t> compute_topological_sort(const CsrGraph& g) {
    IgraphGraph graph = build_graph_owned(g);

    IgraphVectorInt order(0);
    check_igraph(igraph_topological_sorting(graph.ptr(), order.ptr(), IGRAPH_OUT),
                 "igraph_topological_sorting");

    std::vector<int64_t> result(igraph_vector_int_size(order.ptr()));
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(order.ptr()); i++) {
        result[i] = VECTOR(*order.ptr())[i];
    }
    return result;
}

// ── VF2 (sub)isomorphism ──────────────────────────────────────────────
//
// VF2 doesn't use edge weights, but we keep the CSR's `directed` flag
// because igraph's VF2 honours it (and refuses to mix). For sub-isomorphism
// the caller passes the *host* as g1 and the *pattern* as g2.

bool compute_isomorphic_vf2(const CsrGraph& g1, const CsrGraph& g2) {
    if (g1.directed != g2.directed) {
        throw std::invalid_argument("VF2 requires both graphs to have the same directedness");
    }
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_bool_t iso = false;
    check_igraph(igraph_isomorphic_vf2(h1.ptr(), h2.ptr(),
                                       NULL, NULL, NULL, NULL,
                                       &iso, NULL, NULL,
                                       NULL, NULL, NULL),
                 "igraph_isomorphic_vf2");
    return iso;
}

bool compute_subisomorphic_vf2(const CsrGraph& g1, const CsrGraph& g2) {
    if (g1.directed != g2.directed) {
        throw std::invalid_argument("VF2 requires both graphs to have the same directedness");
    }
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_bool_t iso = false;
    check_igraph(igraph_subisomorphic_vf2(h1.ptr(), h2.ptr(),
                                          NULL, NULL, NULL, NULL,
                                          &iso, NULL, NULL,
                                          NULL, NULL, NULL),
                 "igraph_subisomorphic_vf2");
    return iso;
}

IsomorphismResult compute_isomorphism_vf2(const CsrGraph& g1, const CsrGraph& g2) {
    if (g1.directed != g2.directed) {
        throw std::invalid_argument("VF2 requires both graphs to have the same directedness");
    }
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_bool_t iso = false;
    IgraphVectorInt map12(0);
    check_igraph(igraph_isomorphic_vf2(h1.ptr(), h2.ptr(),
                                       NULL, NULL, NULL, NULL,
                                       &iso, map12.ptr(), NULL,
                                       NULL, NULL, NULL),
                 "igraph_isomorphic_vf2");

    IsomorphismResult result;
    result.iso = iso;
    if (iso) {
        igraph_integer_t n = igraph_vector_int_size(map12.ptr());
        result.mapping.resize(n);
        for (igraph_integer_t i = 0; i < n; i++) {
            result.mapping[i] = VECTOR(*map12.ptr())[i];
        }
    }
    return result;
}

IsomorphismResult compute_subgraph_isomorphism_vf2(const CsrGraph& g1, const CsrGraph& g2) {
    if (g1.directed != g2.directed) {
        throw std::invalid_argument("VF2 requires both graphs to have the same directedness");
    }
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_bool_t iso = false;
    IgraphVectorInt map12(0);
    check_igraph(igraph_subisomorphic_vf2(h1.ptr(), h2.ptr(),
                                          NULL, NULL, NULL, NULL,
                                          &iso, map12.ptr(), NULL,
                                          NULL, NULL, NULL),
                 "igraph_subisomorphic_vf2");

    IsomorphismResult result;
    result.iso = iso;
    if (iso) {
        // igraph's subisomorphic_vf2 returns map12 of length |V(g1)|, with
        // -1 entries for host vertices that aren't part of the matched
        // pattern. We return the full vector and let the caller interpret.
        igraph_integer_t n = igraph_vector_int_size(map12.ptr());
        result.mapping.resize(n);
        for (igraph_integer_t i = 0; i < n; i++) {
            result.mapping[i] = VECTOR(*map12.ptr())[i];
        }
    }
    return result;
}

int64_t compute_count_subisomorphisms_vf2(const CsrGraph& g1, const CsrGraph& g2) {
    if (g1.directed != g2.directed) {
        throw std::invalid_argument("VF2 requires both graphs to have the same directedness");
    }
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_integer_t count = 0;
    check_igraph(igraph_count_subisomorphisms_vf2(h1.ptr(), h2.ptr(),
                                                  NULL, NULL, NULL, NULL,
                                                  &count,
                                                  NULL, NULL, NULL),
                 "igraph_count_subisomorphisms_vf2");
    return static_cast<int64_t>(count);
}

} // namespace grafi

// ═══════════════════════════════════════════════════════════════════════
// NIF exports via fine
// ═══════════════════════════════════════════════════════════════════════

namespace {

// Exception thrown by decoders/validators to surface an `{:error, atom}`
// tuple instead of an `{:error, "string"}`.
struct NifError : std::exception {
    std::string atom_name;
    explicit NifError(std::string a) : atom_name(std::move(a)) {}
    const char* what() const noexcept override { return atom_name.c_str(); }
};

ERL_NIF_TERM make_error_atom(ErlNifEnv* env, const char* atom) {
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, atom));
}

ERL_NIF_TERM make_error_string(ErlNifEnv* env, const char* msg) {
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_string(env, msg, ERL_NIF_LATIN1));
}

// Helper: decode a list of int64 from Elixir. Throws NifError on malformed input.
std::vector<int64_t> decode_int_list(ErlNifEnv* env, ERL_NIF_TERM list) {
    unsigned len;
    if (!enif_get_list_length(env, list, &len)) {
        throw NifError("badarg_int_list");
    }
    std::vector<int64_t> result(len);
    ERL_NIF_TERM head, tail = list;
    for (unsigned i = 0; i < len; i++) {
        if (!enif_get_list_cell(env, tail, &head, &tail)) {
            throw NifError("badarg_int_list");
        }
        ErlNifSInt64 val;
        if (!enif_get_int64(env, head, &val)) {
            throw NifError("badarg_int_list");
        }
        result[i] = static_cast<int64_t>(val);
    }
    return result;
}

// Helper: decode a list of doubles from Elixir. Throws NifError on malformed input.
// Accepts both float and integer terms (integers are promoted to double).
std::vector<double> decode_float_list(ErlNifEnv* env, ERL_NIF_TERM list) {
    unsigned len;
    if (!enif_get_list_length(env, list, &len)) {
        throw NifError("badarg_float_list");
    }
    std::vector<double> result(len);
    ERL_NIF_TERM head, tail = list;
    for (unsigned i = 0; i < len; i++) {
        if (!enif_get_list_cell(env, tail, &head, &tail)) {
            throw NifError("badarg_float_list");
        }
        double val;
        if (!enif_get_double(env, head, &val)) {
            // Allow integer weights too — they decode via enif_get_int64.
            ErlNifSInt64 ival;
            if (!enif_get_int64(env, head, &ival)) {
                throw NifError("badarg_float_list");
            }
            val = static_cast<double>(ival);
        }
        result[i] = val;
    }
    return result;
}

// Helper: decode CSR graph from Elixir map. Throws NifError on malformed input.
grafi::CsrGraph decode_csr(ErlNifEnv* env, ERL_NIF_TERM map) {
    grafi::CsrGraph csr;
    ERL_NIF_TERM val;

    if (!enif_is_map(env, map)) {
        throw NifError("badarg_not_a_map");
    }

    if (!enif_get_map_value(env, map, enif_make_atom(env, "row_offsets"), &val)) {
        throw NifError("missing_row_offsets");
    }
    csr.row_offsets = decode_int_list(env, val);

    if (!enif_get_map_value(env, map, enif_make_atom(env, "col_indices"), &val)) {
        throw NifError("missing_col_indices");
    }
    csr.col_indices = decode_int_list(env, val);

    if (!enif_get_map_value(env, map, enif_make_atom(env, "weights"), &val)) {
        throw NifError("missing_weights");
    }
    csr.weights = decode_float_list(env, val);

    if (!enif_get_map_value(env, map, enif_make_atom(env, "n_vertices"), &val)) {
        throw NifError("missing_n_vertices");
    }
    ErlNifSInt64 n_verts;
    if (!enif_get_int64(env, val, &n_verts)) {
        throw NifError("badarg_n_vertices");
    }
    csr.n_vertices = static_cast<int64_t>(n_verts);

    if (!enif_get_map_value(env, map, enif_make_atom(env, "directed"), &val)) {
        throw NifError("missing_directed");
    }
    // Use a 64-byte buffer (was 16) and check the return — atoms can be up
    // to 255 bytes; a 16-byte buffer would silently truncate.
    char atom_buf[64];
    if (!enif_get_atom(env, val, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1)) {
        throw NifError("badarg_directed");
    }
    if (std::strcmp(atom_buf, "true") == 0) {
        csr.directed = true;
    } else if (std::strcmp(atom_buf, "false") == 0) {
        csr.directed = false;
    } else {
        throw NifError("badarg_directed");
    }

    return csr;
}

// Decode + structurally validate in one shot. Translates exceptions to atoms.
grafi::CsrGraph decode_and_validate_csr(ErlNifEnv* env, ERL_NIF_TERM map) {
    auto csr = decode_csr(env, map);
    try {
        grafi::validate_csr_structure(csr);
    } catch (const std::invalid_argument&) {
        throw NifError("invalid_csr");
    }
    return csr;
}

// Helper: encode list of doubles
ERL_NIF_TERM encode_float_list(ErlNifEnv* env, const std::vector<double>& v) {
    std::vector<ERL_NIF_TERM> terms(v.size());
    for (size_t i = 0; i < v.size(); i++) {
        terms[i] = enif_make_double(env, v[i]);
    }
    return enif_make_list_from_array(env, terms.data(), terms.size());
}

// Helper: encode list of int64
ERL_NIF_TERM encode_int_list(ErlNifEnv* env, const std::vector<int64_t>& v) {
    std::vector<ERL_NIF_TERM> terms(v.size());
    for (size_t i = 0; i < v.size(); i++) {
        terms[i] = enif_make_int64(env, v[i]);
    }
    return enif_make_list_from_array(env, terms.data(), terms.size());
}

// Catch-all wrapper that turns C++ exceptions into Elixir error tuples.
// Use as: return run_nif(env, [&]() -> ERL_NIF_TERM { ... });
template <typename F>
ERL_NIF_TERM run_nif(ErlNifEnv* env, F&& body) {
    try {
        return body();
    } catch (const NifError& e) {
        return make_error_atom(env, e.atom_name.c_str());
    } catch (const std::invalid_argument& e) {
        return make_error_string(env, e.what());
    } catch (const std::exception& e) {
        return make_error_string(env, e.what());
    } catch (...) {
        return make_error_atom(env, "unknown_nif_error");
    }
}

} // namespace

// ── NIF: PageRank ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_pagerank(ErlNifEnv* env, int /*argc*/,
                                  const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);

        double damping;
        if (!enif_get_double(env, argv[1], &damping)) {
            return make_error_atom(env, "badarg_damping");
        }
        if (std::isnan(damping) || std::isinf(damping) ||
            damping <= 0.0 || damping >= 1.0) {
            return make_error_atom(env, "invalid_damping");
        }

        int max_iter;
        if (!enif_get_int(env, argv[2], &max_iter)) {
            return make_error_atom(env, "badarg_max_iter");
        }
        if (max_iter <= 0) {
            return make_error_atom(env, "invalid_max_iter");
        }

        auto result = grafi::compute_pagerank(csr, damping, max_iter);
        return encode_float_list(env, result.ranks);
    });
}

// ── NIF: Dijkstra ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_dijkstra(ErlNifEnv* env, int /*argc*/,
                                  const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);

        ErlNifSInt64 source_l, target_l;
        if (!enif_get_int64(env, argv[1], &source_l)) {
            return make_error_atom(env, "badarg_source");
        }
        if (!enif_get_int64(env, argv[2], &target_l)) {
            return make_error_atom(env, "badarg_target");
        }
        int64_t source = static_cast<int64_t>(source_l);
        int64_t target = static_cast<int64_t>(target_l);

        if (source < 0 || source >= csr.n_vertices ||
            target < 0 || target >= csr.n_vertices) {
            return make_error_atom(env, "out_of_bounds");
        }

        // Dijkstra is undefined on negative weights. Reject them up front
        // so callers can fall back to Bellman-Ford in pure Elixir.
        for (double w : csr.weights) {
            if (w < 0.0) {
                return make_error_atom(env, "negative_weight");
            }
        }

        auto result = grafi::compute_dijkstra(csr, source, target);

        if (result.found) {
            return enif_make_tuple3(env,
                enif_make_atom(env, "ok"),
                encode_int_list(env, result.path),
                enif_make_double(env, result.distance));
        } else {
            return enif_make_atom(env, "no_path");
        }
    });
}

// ── NIF: Betweenness centrality ────────────────────────────────────────

static ERL_NIF_TERM nif_betweenness(ErlNifEnv* env, int /*argc*/,
                                     const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        auto result = grafi::compute_betweenness(csr);
        return encode_float_list(env, result.scores);
    });
}

// ── NIF: Closeness centrality ──────────────────────────────────────────

static ERL_NIF_TERM nif_closeness(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        auto result = grafi::compute_closeness(csr);
        return encode_float_list(env, result.scores);
    });
}

// ── NIF: Louvain community detection ───────────────────────────────────

static ERL_NIF_TERM nif_louvain(ErlNifEnv* env, int /*argc*/,
                                 const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        auto result = grafi::compute_louvain(csr);

        return enif_make_tuple3(env,
            encode_int_list(env, result.membership),
            enif_make_double(env, result.modularity),
            enif_make_int64(env, result.n_communities));
    });
}

// ── NIF: Label propagation ─────────────────────────────────────────────

static ERL_NIF_TERM nif_label_propagation(ErlNifEnv* env, int /*argc*/,
                                           const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        auto result = grafi::compute_label_propagation(csr);

        return enif_make_tuple3(env,
            encode_int_list(env, result.membership),
            enif_make_double(env, result.modularity),
            enif_make_int64(env, result.n_communities));
    });
}

// ── NIF: Leiden ─────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_leiden(ErlNifEnv* env, int /*argc*/,
                                const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);

        double resolution;
        if (!enif_get_double(env, argv[1], &resolution)) {
            return make_error_atom(env, "badarg_resolution");
        }
        if (std::isnan(resolution) || std::isinf(resolution) || resolution <= 0.0) {
            return make_error_atom(env, "invalid_resolution");
        }

        auto result = grafi::compute_leiden(csr, resolution);

        return enif_make_tuple3(env,
            encode_int_list(env, result.membership),
            enif_make_double(env, result.modularity),
            enif_make_int64(env, result.n_communities));
    });
}

// ── NIF: Strongly connected components ─────────────────────────────────

static ERL_NIF_TERM nif_scc(ErlNifEnv* env, int /*argc*/,
                             const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        auto result = grafi::compute_scc(csr);

        return enif_make_tuple2(env,
            encode_int_list(env, result.membership),
            enif_make_int64(env, result.n_components));
    });
}

// ── NIF: Is DAG? ───────────────────────────────────────────────────────

static ERL_NIF_TERM nif_is_acyclic(ErlNifEnv* env, int /*argc*/,
                                    const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        bool acyclic = grafi::compute_is_acyclic(csr);
        return enif_make_atom(env, acyclic ? "true" : "false");
    });
}

// ── NIF: Topological sort ──────────────────────────────────────────────

static ERL_NIF_TERM nif_topological_sort(ErlNifEnv* env, int /*argc*/,
                                          const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        auto result = grafi::compute_topological_sort(csr);
        return encode_int_list(env, result);
    });
}

// ── NIF: VF2 isomorphism (boolean) ─────────────────────────────────────

static ERL_NIF_TERM nif_isomorphic_vf2(ErlNifEnv* env, int /*argc*/,
                                        const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr1 = decode_and_validate_csr(env, argv[0]);
        auto csr2 = decode_and_validate_csr(env, argv[1]);
        if (csr1.directed != csr2.directed) {
            return make_error_atom(env, "mixed_directedness");
        }
        bool iso = grafi::compute_isomorphic_vf2(csr1, csr2);
        return enif_make_tuple2(env,
            enif_make_atom(env, "ok"),
            enif_make_atom(env, iso ? "true" : "false"));
    });
}

// ── NIF: VF2 sub-isomorphism (boolean) ─────────────────────────────────

static ERL_NIF_TERM nif_subisomorphic_vf2(ErlNifEnv* env, int /*argc*/,
                                           const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr1 = decode_and_validate_csr(env, argv[0]);
        auto csr2 = decode_and_validate_csr(env, argv[1]);
        if (csr1.directed != csr2.directed) {
            return make_error_atom(env, "mixed_directedness");
        }
        bool iso = grafi::compute_subisomorphic_vf2(csr1, csr2);
        return enif_make_tuple2(env,
            enif_make_atom(env, "ok"),
            enif_make_atom(env, iso ? "true" : "false"));
    });
}

// ── NIF: VF2 isomorphism mapping ───────────────────────────────────────

static ERL_NIF_TERM nif_isomorphism_vf2(ErlNifEnv* env, int /*argc*/,
                                         const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr1 = decode_and_validate_csr(env, argv[0]);
        auto csr2 = decode_and_validate_csr(env, argv[1]);
        if (csr1.directed != csr2.directed) {
            return make_error_atom(env, "mixed_directedness");
        }
        auto result = grafi::compute_isomorphism_vf2(csr1, csr2);
        if (!result.iso) {
            return make_error_atom(env, "no_isomorphism");
        }
        return enif_make_tuple2(env,
            enif_make_atom(env, "ok"),
            encode_int_list(env, result.mapping));
    });
}

// ── NIF: VF2 subgraph isomorphism mapping ──────────────────────────────

static ERL_NIF_TERM nif_subgraph_isomorphism_vf2(ErlNifEnv* env, int /*argc*/,
                                                  const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr1 = decode_and_validate_csr(env, argv[0]);
        auto csr2 = decode_and_validate_csr(env, argv[1]);
        if (csr1.directed != csr2.directed) {
            return make_error_atom(env, "mixed_directedness");
        }
        auto result = grafi::compute_subgraph_isomorphism_vf2(csr1, csr2);
        if (!result.iso) {
            return make_error_atom(env, "no_isomorphism");
        }
        return enif_make_tuple2(env,
            enif_make_atom(env, "ok"),
            encode_int_list(env, result.mapping));
    });
}

// ── NIF: VF2 count of subisomorphisms ──────────────────────────────────

static ERL_NIF_TERM nif_count_subisomorphisms_vf2(ErlNifEnv* env, int /*argc*/,
                                                   const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr1 = decode_and_validate_csr(env, argv[0]);
        auto csr2 = decode_and_validate_csr(env, argv[1]);
        if (csr1.directed != csr2.directed) {
            return make_error_atom(env, "mixed_directedness");
        }
        int64_t count = grafi::compute_count_subisomorphisms_vf2(csr1, csr2);
        return enif_make_tuple2(env,
            enif_make_atom(env, "ok"),
            enif_make_int64(env, count));
    });
}

// ═══════════════════════════════════════════════════════════════════════
// NIF registration
// ═══════════════════════════════════════════════════════════════════════

static ErlNifFunc nif_funcs[] = {
    {"nif_pagerank",           3, nif_pagerank,           ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_dijkstra",           3, nif_dijkstra,           ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_betweenness",        1, nif_betweenness,        ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_closeness",          1, nif_closeness,          ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_louvain",            1, nif_louvain,            ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_label_propagation",  1, nif_label_propagation,  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_leiden",             2, nif_leiden,              ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_scc",                1, nif_scc,                ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_is_acyclic",         1, nif_is_acyclic,         0},
    {"nif_topological_sort",   1, nif_topological_sort,   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_isomorphic_vf2",     2, nif_isomorphic_vf2,     ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_subisomorphic_vf2",  2, nif_subisomorphic_vf2,  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_isomorphism_vf2",    2, nif_isomorphism_vf2,    ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_subgraph_isomorphism_vf2", 2, nif_subgraph_isomorphism_vf2, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_count_subisomorphisms_vf2", 2, nif_count_subisomorphisms_vf2, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(Elixir.Grafi.NIF, nif_funcs, NULL, NULL, NULL, NULL)
