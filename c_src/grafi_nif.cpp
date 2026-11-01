// c_src/grafi_nif.cpp
// Grafi NIF — high-performance graph algorithms via igraph + fine
//
// Each NIF receives the graph in CSR format from Elixir, converts to
// igraph_t, runs the algorithm, and returns results as Elixir terms.
// Everything except the O(1) `nif_loaded/0` probe runs on a dirty CPU
// scheduler (see `nif_funcs` at the bottom).
//
// Compatible with igraph >= 1.0.0

#include "grafi_nif.h"
#include <fine.hpp>
#include <stdexcept>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
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
    // Pre-sized edge list (2 entries per edge), filled by index.
    IgraphVectorInt edges(static_cast<igraph_int_t>(2 * csr.col_indices.size()));
    igraph_int_t k = 0;
    for (int64_t row = 0; row < csr.n_vertices; row++) {
        for (int64_t j = csr.row_offsets[row]; j < csr.row_offsets[row + 1]; j++) {
            VECTOR(*edges.ptr())[k++] = row;
            VECTOR(*edges.ptr())[k++] = csr.col_indices[j];
        }
    }

    igraph_t graph;
    check_igraph(igraph_create(&graph, edges.ptr(), csr.n_vertices,
                               csr.directed ? IGRAPH_DIRECTED : IGRAPH_UNDIRECTED),
                 "igraph_create");
    return graph;
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

static std::vector<int64_t> copy_int_vector(const igraph_vector_int_t* v) {
    const igraph_int_t n = igraph_vector_int_size(v);
    std::vector<int64_t> out(n);
    for (igraph_int_t i = 0; i < n; i++) out[i] = VECTOR(*v)[i];
    return out;
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

    IgraphVectorInt vertices(0);
    IgraphVectorInt edges(0);
    check_igraph(igraph_get_shortest_path_dijkstra(
                     graph.ptr(), vertices.ptr(), edges.ptr(),
                     source, target, weights.ptr(),
                     g.directed ? IGRAPH_OUT : IGRAPH_ALL),
                 "igraph_get_shortest_path_dijkstra");

    ShortestPathResult result;
    result.found = igraph_vector_int_size(vertices.ptr()) > 0;
    result.distance = result.found ? 0.0 : IGRAPH_INFINITY;
    if (result.found) {
        result.path = copy_int_vector(vertices.ptr());
        // Sum by edge id. On a multigraph the path runs over one specific
        // parallel edge, which a vertex-pair lookup can't identify.
        for (igraph_int_t i = 0; i < igraph_vector_int_size(edges.ptr()); i++) {
            result.distance += VECTOR(*weights.ptr())[VECTOR(*edges.ptr())[i]];
        }
    }
    return result;
}

// igraph counts each unordered pair once on undirected graphs. Normalization
// is applied here rather than through igraph's flag so both engines share
// one formula: 2/((n-1)(n-2)) undirected, 1/((n-1)(n-2)) directed, none for
// n <= 2.
CentralityResult compute_betweenness(const CsrGraph& g, bool weighted, bool normalized) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    if (weighted) fill_weights(g, weights);

    IgraphVector result(0);
    check_igraph(igraph_betweenness(graph.ptr(), weighted ? weights.ptr() : NULL,
                                    result.ptr(), igraph_vss_all(),
                                    g.directed, false),
                 "igraph_betweenness");

    const double n = static_cast<double>(g.n_vertices);
    const double scale = (normalized && g.n_vertices > 2)
        ? (g.directed ? 1.0 : 2.0) / ((n - 1.0) * (n - 2.0))
        : 1.0;

    CentralityResult cr;
    cr.scores.resize(igraph_vector_size(result.ptr()));
    for (igraph_int_t i = 0; i < igraph_vector_size(result.ptr()); i++) {
        cr.scores[i] = VECTOR(*result.ptr())[i] * scale;
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

// `objective` selects modularity (vertex strengths and the γ/(2m) scaling are
// handled inside igraph_community_leiden_simple) or CPM. The reported
// modularity is always igraph_modularity at resolution 1, so it is comparable
// to Louvain's whatever objective and resolution produced the partition.
CommunityResult compute_leiden(const CsrGraph& g, double resolution,
                               igraph_leiden_objective_t objective) {
    IgraphGraph graph = build_graph_owned(g);
    IgraphVector weights;
    fill_weights(g, weights);

    IgraphVectorInt membership(0);
    igraph_real_t quality;
    igraph_int_t nb_clusters;

    check_igraph(igraph_community_leiden_simple(graph.ptr(), weights.ptr(), objective,
                                                resolution, 0.01, false, -1,
                                                membership.ptr(), &nb_clusters, &quality),
                 "igraph_community_leiden_simple");

    igraph_real_t modularity;
    check_igraph(igraph_modularity(graph.ptr(), membership.ptr(), weights.ptr(),
                                   1.0, false, &modularity),
                 "igraph_modularity");

    CommunityResult cr;
    cr.modularity = modularity;
    cr.n_communities = nb_clusters;
    cr.membership = copy_int_vector(membership.ptr());
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

// Returns false (leaving `out` empty) if the graph has a cycle, so the caller
// can report {:error, :has_cycle} rather than an opaque igraph error string.
// igraph's order is Kahn's algorithm with a FIFO of sources seeded in vertex
// index order; Grafi.DAG's Elixir engine reproduces it exactly.
bool compute_topological_sort(const CsrGraph& g, std::vector<int64_t>& out) {
    IgraphGraph graph = build_graph_owned(g);

    igraph_bool_t is_dag;
    check_igraph(igraph_is_dag(graph.ptr(), &is_dag), "igraph_is_dag");
    if (!is_dag) return false;

    IgraphVectorInt order(0);
    check_igraph(igraph_topological_sorting(graph.ptr(), order.ptr(), IGRAPH_OUT),
                 "igraph_topological_sorting");
    out = copy_int_vector(order.ptr());
    return true;
}

// ── VF2 (sub)isomorphism ──────────────────────────────────────────────
//
// VF2 doesn't use edge weights, but we keep the CSR's `directed` flag
// because igraph's VF2 honours it (and refuses to mix). For sub-isomorphism
// the caller passes the *host* as g1 and the *pattern* as g2.
//
// VF2 is exponential in the worst case. The deadline is enforced through the
// node-compatibility callback: once it passes, the callback rejects every
// candidate pair, so the search unwinds through igraph's normal success path.
// igraph's interruption mechanism is not used because an interrupted VF2
// call segfaults during cleanup in igraph 1.0.1.

// Raw-NIF backstop. kMaxVf2TimeoutMs mirrors @max_timeout in
// Grafi.Algo.Isomorphism, which rejects a larger :timeout; it is far below
// the ms→ns overflow point (~9.2e12 ms). A larger value reaching the NIF
// directly could overflow steady_clock's nanosecond time_point when added to
// now(), so it means "no deadline".
static constexpr int64_t kMaxVf2TimeoutMs = 0xFFFFFFFFLL;

Vf2Budget::Vf2Budget(int64_t timeout_ms)
    : enabled(timeout_ms > 0 && timeout_ms <= kMaxVf2TimeoutMs) {
    if (enabled) {
        deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    }
}

static igraph_bool_t vf2_budget_compat(const igraph_t*, const igraph_t*,
                                       const igraph_int_t, const igraph_int_t,
                                       void* arg) {
    auto* budget = static_cast<Vf2Budget*>(arg);
    if (budget->timed_out) return false;
    // Checking the clock on every call would dominate a tight search. One
    // call is ~0.1 µs (spike: ~1M calls per 100 ms), so every 1024th call
    // bounds the overshoot to roughly 0.1 ms.
    if ((++budget->tick & 1023u) == 0 &&
        std::chrono::steady_clock::now() >= budget->deadline) {
        budget->timed_out = true;
        return false;
    }
    return true;
}

static igraph_isocompat_t* budget_compat_fn(const Vf2Budget& budget) {
    return budget.enabled ? vf2_budget_compat : nullptr;
}

static void require_same_directedness(const CsrGraph& g1, const CsrGraph& g2) {
    if (g1.directed != g2.directed) {
        throw std::invalid_argument("VF2 requires both graphs to have the same directedness");
    }
}

IsomorphismResult compute_isomorphism_vf2(const CsrGraph& g1, const CsrGraph& g2,
                                          bool want_mapping, Vf2Budget& budget) {
    require_same_directedness(g1, g2);
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_bool_t iso = false;
    IgraphVectorInt map12(0);
    check_igraph(igraph_isomorphic_vf2(h1.ptr(), h2.ptr(),
                                       NULL, NULL, NULL, NULL,
                                       &iso, want_mapping ? map12.ptr() : NULL, NULL,
                                       budget_compat_fn(budget), NULL, &budget),
                 "igraph_isomorphic_vf2");

    IsomorphismResult result;
    result.iso = iso;
    if (iso && want_mapping) result.mapping = copy_int_vector(map12.ptr());
    return result;
}

// igraph's subisomorphic_vf2 returns map12 of length |V(g1)|, with -1 entries
// for host vertices that aren't part of the matched pattern. The full vector
// is returned and the caller interprets it.
IsomorphismResult compute_subgraph_isomorphism_vf2(const CsrGraph& g1, const CsrGraph& g2,
                                                   bool want_mapping, Vf2Budget& budget) {
    require_same_directedness(g1, g2);
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_bool_t iso = false;
    IgraphVectorInt map12(0);
    check_igraph(igraph_subisomorphic_vf2(h1.ptr(), h2.ptr(),
                                          NULL, NULL, NULL, NULL,
                                          &iso, want_mapping ? map12.ptr() : NULL, NULL,
                                          budget_compat_fn(budget), NULL, &budget),
                 "igraph_subisomorphic_vf2");

    IsomorphismResult result;
    result.iso = iso;
    if (iso && want_mapping) result.mapping = copy_int_vector(map12.ptr());
    return result;
}

int64_t compute_count_subisomorphisms_vf2(const CsrGraph& g1, const CsrGraph& g2,
                                          Vf2Budget& budget) {
    require_same_directedness(g1, g2);
    IgraphGraph h1 = build_graph_owned(g1);
    IgraphGraph h2 = build_graph_owned(g2);

    igraph_int_t count = 0;
    check_igraph(igraph_count_subisomorphisms_vf2(h1.ptr(), h2.ptr(),
                                                  NULL, NULL, NULL, NULL,
                                                  &count,
                                                  budget_compat_fn(budget), NULL, &budget),
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

// Error reasons travel as binaries (Elixir strings), not charlists.
ERL_NIF_TERM make_error_string(ErlNifEnv* env, const char* msg) {
    const size_t len = std::strlen(msg);
    ERL_NIF_TERM bin;
    unsigned char* buf = enif_make_new_binary(env, len, &bin);
    std::memcpy(buf, msg, len);
    return enif_make_tuple2(env, enif_make_atom(env, "error"), bin);
}

// NaN/±Inf have no Erlang float representation (enif_make_double raises
// badarg on them). Map them to 0.0, the Elixir-side contract for undefined
// scores, e.g. closeness of a vertex that reaches nothing.
ERL_NIF_TERM make_finite_double(ErlNifEnv* env, double x) {
    return enif_make_double(env, std::isfinite(x) ? x : 0.0);
}

// Input guards for algorithms that igraph either rejects with an error code
// (which would surface as an opaque string) or silently mis-computes.
void require_undirected(const grafi::CsrGraph& csr) {
    if (csr.directed) throw NifError("directed_unsupported");
}

void require_non_negative_weights(const grafi::CsrGraph& csr) {
    for (double w : csr.weights) {
        if (w < 0.0) throw NifError("negative_weight");
    }
}

// Closeness and weighted betweenness: a zero-length edge makes distinct
// vertices coincide, so igraph's distances (and path counts) are not
// meaningful there. Grafi.Args.positive_weights!/1 rejects these first.
void require_positive_weights(const grafi::CsrGraph& csr) {
    for (double w : csr.weights) {
        if (w <= 0.0) throw NifError("non_positive_weight");
    }
}

// Helper: decode one CSR array, a binary of native-endian 8-byte elements
// (`signed-native-64` / `float-native-64` in Elixir). One memcpy replaces
// per-element term decoding. The data is copied rather than aliased because a
// sub-binary's data pointer need not be 8-byte aligned.
template <typename T>
std::vector<T> decode_array_binary(ErlNifEnv* env, ERL_NIF_TERM term, const char* error_atom) {
    static_assert(sizeof(T) == 8, "CSR arrays use 8-byte elements");
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin) || bin.size % sizeof(T) != 0) {
        throw NifError(error_atom);
    }
    std::vector<T> out(bin.size / sizeof(T));
    if (!out.empty()) std::memcpy(out.data(), bin.data, bin.size);
    return out;
}

// Helper: decode an Elixir boolean. Throws NifError(error_atom) otherwise.
bool decode_bool(ErlNifEnv* env, ERL_NIF_TERM term, const char* error_atom) {
    if (enif_is_identical(term, enif_make_atom(env, "true"))) return true;
    if (enif_is_identical(term, enif_make_atom(env, "false"))) return false;
    throw NifError(error_atom);
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
    csr.row_offsets = decode_array_binary<int64_t>(env, val, "badarg_row_offsets");

    if (!enif_get_map_value(env, map, enif_make_atom(env, "col_indices"), &val)) {
        throw NifError("missing_col_indices");
    }
    csr.col_indices = decode_array_binary<int64_t>(env, val, "badarg_col_indices");

    if (!enif_get_map_value(env, map, enif_make_atom(env, "weights"), &val)) {
        throw NifError("missing_weights");
    }
    csr.weights = decode_array_binary<double>(env, val, "badarg_weights");

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
    csr.directed = decode_bool(env, val, "badarg_directed");

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
        terms[i] = make_finite_double(env, v[i]);
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

// igraph 1.0.x is built with IGRAPH_THREAD_SAFE 1, so the error, warning and
// fatal handlers are thread-local. NIFs run on whichever (dirty) scheduler
// thread picks them up, so each thread installs the handlers the first time
// it enters a NIF. Without this a dirty thread keeps igraph's default
// handler, which calls abort() and takes the whole VM down (V1).
//
// No interruption handler is installed: an interrupted VF2 call segfaults
// while igraph 1.0.1 unwinds its cleanup stack (see the nif-safety
// scratchpad). VF2 is bounded by a compat-callback deadline instead.
[[noreturn]] void grafi_fatal_handler(const char* reason, const char* file, int line) {
    std::fprintf(stderr, "grafi_nif: igraph fatal error at %s:%d: %s\n", file, line, reason);
    std::abort();
}

void install_thread_handlers() {
    static thread_local bool installed = false;
    if (installed) return;
    igraph_set_error_handler(igraph_error_handler_ignore);
    igraph_set_warning_handler(igraph_warning_handler_ignore);
    igraph_set_fatal_handler(grafi_fatal_handler);
    installed = true;
}

// Catch-all wrapper that turns C++ exceptions into Elixir error tuples.
// Use as: return run_nif(env, [&]() -> ERL_NIF_TERM { ... });
template <typename F>
ERL_NIF_TERM run_nif(ErlNifEnv* env, F&& body) {
    install_thread_handlers();
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
        // igraph silently accepts negative PageRank weights.
        require_non_negative_weights(csr);

        double damping;
        if (!enif_get_double(env, argv[1], &damping)) {
            return make_error_atom(env, "badarg_damping");
        }
        if (std::isnan(damping) || std::isinf(damping) ||
            damping < 0.0 || damping >= 1.0) {
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

        // Dijkstra is undefined on negative weights.
        require_non_negative_weights(csr);

        auto result = grafi::compute_dijkstra(csr, source, target);

        if (result.found) {
            return enif_make_tuple3(env,
                enif_make_atom(env, "ok"),
                encode_int_list(env, result.path),
                make_finite_double(env, result.distance));
        } else {
            return enif_make_atom(env, "no_path");
        }
    });
}

// ── NIF: Betweenness centrality ────────────────────────────────────────

// argv: (csr, weighted?, normalized?)
static ERL_NIF_TERM nif_betweenness(ErlNifEnv* env, int /*argc*/,
                                     const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        const bool weighted = decode_bool(env, argv[1], "badarg_weighted");
        const bool normalized = decode_bool(env, argv[2], "badarg_normalized");
        if (weighted) require_positive_weights(csr);
        auto result = grafi::compute_betweenness(csr, weighted, normalized);
        return encode_float_list(env, result.scores);
    });
}

// ── NIF: Closeness centrality ──────────────────────────────────────────

static ERL_NIF_TERM nif_closeness(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        require_positive_weights(csr);
        auto result = grafi::compute_closeness(csr);
        return encode_float_list(env, result.scores);
    });
}

// ── Community detection ────────────────────────────────────────────────

static ERL_NIF_TERM encode_community(ErlNifEnv* env, const grafi::CommunityResult& r) {
    return enif_make_tuple3(env,
        encode_int_list(env, r.membership),
        make_finite_double(env, r.modularity),
        enif_make_int64(env, r.n_communities));
}

static ERL_NIF_TERM nif_louvain(ErlNifEnv* env, int /*argc*/,
                                 const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        require_undirected(csr);
        require_non_negative_weights(csr);
        return encode_community(env, grafi::compute_louvain(csr));
    });
}

// Label propagation runs in IGRAPH_ALL mode, which igraph accepts on
// directed graphs, so there is no direction check here.
static ERL_NIF_TERM nif_label_propagation(ErlNifEnv* env, int /*argc*/,
                                           const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        require_non_negative_weights(csr);
        return encode_community(env, grafi::compute_label_propagation(csr));
    });
}

// argv: (csr, resolution, objective) where objective is :modularity | :cpm.
static ERL_NIF_TERM nif_leiden(ErlNifEnv* env, int /*argc*/,
                                const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto csr = decode_and_validate_csr(env, argv[0]);
        require_undirected(csr);
        // igraph silently accepts negative Leiden weights.
        require_non_negative_weights(csr);

        double resolution;
        if (!enif_get_double(env, argv[1], &resolution)) {
            return make_error_atom(env, "badarg_resolution");
        }
        if (std::isnan(resolution) || std::isinf(resolution) || resolution <= 0.0) {
            return make_error_atom(env, "invalid_resolution");
        }

        igraph_leiden_objective_t objective;
        if (enif_is_identical(argv[2], enif_make_atom(env, "modularity"))) {
            objective = IGRAPH_LEIDEN_OBJECTIVE_MODULARITY;
        } else if (enif_is_identical(argv[2], enif_make_atom(env, "cpm"))) {
            objective = IGRAPH_LEIDEN_OBJECTIVE_CPM;
        } else {
            return make_error_atom(env, "badarg_objective");
        }

        return encode_community(env, grafi::compute_leiden(csr, resolution, objective));
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
        std::vector<int64_t> order;
        if (!grafi::compute_topological_sort(csr, order)) {
            return make_error_atom(env, "has_cycle");
        }
        return enif_make_tuple2(env, enif_make_atom(env, "ok"), encode_int_list(env, order));
    });
}

// ── NIF: VF2 (sub)isomorphism ──────────────────────────────────────────
//
// Every VF2 NIF takes (g1, g2, timeout_ms). For the sub-isomorphism variants
// g1 is the host and g2 the pattern. A timeout_ms of 0, or anything above
// kMaxVf2TimeoutMs, disables the deadline; a search that hits it returns
// {:error, :timeout}. A negative timeout_ms, or one that is not an int64
// (e.g. 2**63), returns {:error, :badarg_timeout}.

struct Vf2Args {
    grafi::CsrGraph g1;
    grafi::CsrGraph g2;
    int64_t timeout_ms;
};

static Vf2Args decode_vf2_args(ErlNifEnv* env, const ERL_NIF_TERM argv[]) {
    Vf2Args args{decode_and_validate_csr(env, argv[0]),
                 decode_and_validate_csr(env, argv[1]), 0};
    ErlNifSInt64 timeout_ms;
    if (!enif_get_int64(env, argv[2], &timeout_ms) || timeout_ms < 0) {
        throw NifError("badarg_timeout");
    }
    if (args.g1.directed != args.g2.directed) {
        throw NifError("mixed_directedness");
    }
    args.timeout_ms = static_cast<int64_t>(timeout_ms);
    return args;
}

static ERL_NIF_TERM encode_vf2_bool(ErlNifEnv* env, const grafi::IsomorphismResult& r,
                                    const grafi::Vf2Budget& budget) {
    if (!r.iso && budget.timed_out) return make_error_atom(env, "timeout");
    return enif_make_tuple2(env,
        enif_make_atom(env, "ok"),
        enif_make_atom(env, r.iso ? "true" : "false"));
}

static ERL_NIF_TERM encode_vf2_mapping(ErlNifEnv* env, const grafi::IsomorphismResult& r,
                                       const grafi::Vf2Budget& budget) {
    if (!r.iso) {
        return make_error_atom(env, budget.timed_out ? "timeout" : "no_isomorphism");
    }
    return enif_make_tuple2(env,
        enif_make_atom(env, "ok"),
        encode_int_list(env, r.mapping));
}

static ERL_NIF_TERM nif_isomorphic_vf2(ErlNifEnv* env, int /*argc*/,
                                        const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto args = decode_vf2_args(env, argv);
        grafi::Vf2Budget budget(args.timeout_ms);
        auto r = grafi::compute_isomorphism_vf2(args.g1, args.g2, false, budget);
        return encode_vf2_bool(env, r, budget);
    });
}

static ERL_NIF_TERM nif_subisomorphic_vf2(ErlNifEnv* env, int /*argc*/,
                                           const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto args = decode_vf2_args(env, argv);
        grafi::Vf2Budget budget(args.timeout_ms);
        auto r = grafi::compute_subgraph_isomorphism_vf2(args.g1, args.g2, false, budget);
        return encode_vf2_bool(env, r, budget);
    });
}

static ERL_NIF_TERM nif_isomorphism_vf2(ErlNifEnv* env, int /*argc*/,
                                         const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto args = decode_vf2_args(env, argv);
        grafi::Vf2Budget budget(args.timeout_ms);
        auto r = grafi::compute_isomorphism_vf2(args.g1, args.g2, true, budget);
        return encode_vf2_mapping(env, r, budget);
    });
}

static ERL_NIF_TERM nif_subgraph_isomorphism_vf2(ErlNifEnv* env, int /*argc*/,
                                                  const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto args = decode_vf2_args(env, argv);
        grafi::Vf2Budget budget(args.timeout_ms);
        auto r = grafi::compute_subgraph_isomorphism_vf2(args.g1, args.g2, true, budget);
        return encode_vf2_mapping(env, r, budget);
    });
}

static ERL_NIF_TERM nif_count_subisomorphisms_vf2(ErlNifEnv* env, int /*argc*/,
                                                   const ERL_NIF_TERM argv[]) {
    return run_nif(env, [&]() -> ERL_NIF_TERM {
        auto args = decode_vf2_args(env, argv);
        grafi::Vf2Budget budget(args.timeout_ms);
        int64_t count = grafi::compute_count_subisomorphisms_vf2(args.g1, args.g2, budget);
        if (budget.timed_out) return make_error_atom(env, "timeout");
        return enif_make_tuple2(env,
            enif_make_atom(env, "ok"),
            enif_make_int64(env, count));
    });
}

// ── NIF: load probe ────────────────────────────────────────────────────

// O(1), so it stays on a normal scheduler. Grafi.NIF.load_nif/0 calls it to
// confirm the library is callable.
static ERL_NIF_TERM nif_loaded(ErlNifEnv* env, int /*argc*/,
                               const ERL_NIF_TERM /*argv*/[]) {
    return enif_make_atom(env, "ok");
}

// ═══════════════════════════════════════════════════════════════════════
// NIF registration
// ═══════════════════════════════════════════════════════════════════════

// Module load callback. igraph's default error handler calls abort(); the
// non-aborting handler makes igraph return error codes instead, so
// check_igraph() can throw and run_nif() can turn the failure into an
// {:error, _} tuple. The handlers are thread-local (IGRAPH_THREAD_SAFE 1), so
// this only covers the loading thread; every NIF entry point re-installs
// them for its own thread via run_nif() -> install_thread_handlers().
static int grafi_nif_load(ErlNifEnv* /*env*/, void** /*priv_data*/,
                          ERL_NIF_TERM /*load_info*/) {
    install_thread_handlers();
    return 0;
}

// Every NIF that builds an igraph graph from a CSR is O(V + E) or worse and
// runs on a dirty CPU scheduler. Only the O(1) load probe stays on a normal
// scheduler.
static ErlNifFunc nif_funcs[] = {
    {"nif_loaded",             0, nif_loaded,             0},
    {"nif_pagerank",           3, nif_pagerank,           ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_dijkstra",           3, nif_dijkstra,           ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_betweenness",        3, nif_betweenness,        ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_closeness",          1, nif_closeness,          ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_louvain",            1, nif_louvain,            ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_label_propagation",  1, nif_label_propagation,  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_leiden",             3, nif_leiden,             ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_scc",                1, nif_scc,                ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_is_acyclic",         1, nif_is_acyclic,         ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_topological_sort",   1, nif_topological_sort,   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_isomorphic_vf2",     3, nif_isomorphic_vf2,     ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_subisomorphic_vf2",  3, nif_subisomorphic_vf2,  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_isomorphism_vf2",    3, nif_isomorphism_vf2,    ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_subgraph_isomorphism_vf2",  3, nif_subgraph_isomorphism_vf2,  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_count_subisomorphisms_vf2", 3, nif_count_subisomorphisms_vf2, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(Elixir.Grafi.NIF, nif_funcs, grafi_nif_load, NULL, NULL, NULL)
