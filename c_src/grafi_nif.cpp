// c_src/grafi_nif.cpp
// Grafi NIF — high-performance graph algorithms via igraph + fine
//
// Each NIF receives the graph in CSR format from Elixir, converts to
// igraph_t, runs the algorithm, and returns results as Elixir terms.
// All NIFs are scheduled on dirty CPU schedulers via fine.

#include "grafi_nif.h"
#include <fine.hpp>
#include <stdexcept>
#include <algorithm>
#include <cmath>

namespace grafi {

// ═══════════════════════════════════════════════════════════════════════
// Graph conversion
// ═══════════════════════════════════════════════════════════════════════

igraph_t csr_to_igraph(const CsrGraph& csr) {
    igraph_t graph;
    igraph_vector_int_t edges;
    igraph_vector_int_init(&edges, 0);

    // Convert CSR to edge list
    for (int64_t row = 0; row < csr.n_vertices; row++) {
        for (int64_t j = csr.row_offsets[row]; j < csr.row_offsets[row + 1]; j++) {
            igraph_vector_int_push_back(&edges, row);
            igraph_vector_int_push_back(&edges, csr.col_indices[j]);
        }
    }

    igraph_create(&graph, &edges, csr.n_vertices,
                  csr.directed ? IGRAPH_DIRECTED : IGRAPH_UNDIRECTED);
    igraph_vector_int_destroy(&edges);
    return graph;
}

igraph_vector_t csr_to_weights(const CsrGraph& csr) {
    igraph_vector_t weights;
    igraph_vector_init(&weights, csr.weights.size());
    for (size_t i = 0; i < csr.weights.size(); i++) {
        VECTOR(weights)[i] = csr.weights[i];
    }
    return weights;
}

// ═══════════════════════════════════════════════════════════════════════
// Algorithm implementations
// ═══════════════════════════════════════════════════════════════════════

PageRankResult compute_pagerank(const CsrGraph& g, double damping, int max_iter) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_t weights = csr_to_weights(g);
    igraph_vector_t result;
    igraph_real_t eigenvalue;

    igraph_vector_init(&result, 0);

    igraph_pagerank(&graph, IGRAPH_PAGERANK_ALGO_PRPACK,
                    &result, &eigenvalue,
                    igraph_vss_all(), IGRAPH_DIRECTED,
                    damping, &weights, NULL);

    PageRankResult pr;
    pr.ranks.resize(igraph_vector_size(&result));
    for (igraph_integer_t i = 0; i < igraph_vector_size(&result); i++) {
        pr.ranks[i] = VECTOR(result)[i];
    }

    igraph_vector_destroy(&result);
    igraph_vector_destroy(&weights);
    igraph_destroy(&graph);
    return pr;
}

ShortestPathResult compute_dijkstra(const CsrGraph& g, int64_t source, int64_t target) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_t weights = csr_to_weights(g);

    // Get shortest path vertices
    igraph_vector_int_list_t paths;
    igraph_vector_int_list_init(&paths, 0);

    igraph_vector_int_t targets;
    igraph_vector_int_init(&targets, 1);
    VECTOR(targets)[0] = target;

    igraph_get_shortest_paths_dijkstra(&graph, &paths, NULL,
                                       source, igraph_vss_vector(&targets),
                                       &weights, IGRAPH_OUT, NULL, NULL);

    ShortestPathResult result;
    if (igraph_vector_int_list_size(&paths) > 0) {
        igraph_vector_int_t* path = igraph_vector_int_list_get_ptr(&paths, 0);
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
                igraph_get_eid(&graph, &eid, result.path[i], result.path[i+1],
                               IGRAPH_DIRECTED, 0);
                if (eid >= 0) {
                    result.distance += VECTOR(weights)[eid];
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

    igraph_vector_int_destroy(&targets);
    igraph_vector_int_list_destroy(&paths);
    igraph_vector_destroy(&weights);
    igraph_destroy(&graph);
    return result;
}

CentralityResult compute_betweenness(const CsrGraph& g) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_t weights = csr_to_weights(g);
    igraph_vector_t result;
    igraph_vector_init(&result, 0);

    igraph_betweenness(&graph, &result, igraph_vss_all(),
                       IGRAPH_DIRECTED, &weights);

    CentralityResult cr;
    cr.scores.resize(igraph_vector_size(&result));
    for (igraph_integer_t i = 0; i < igraph_vector_size(&result); i++) {
        cr.scores[i] = VECTOR(result)[i];
    }

    igraph_vector_destroy(&result);
    igraph_vector_destroy(&weights);
    igraph_destroy(&graph);
    return cr;
}

CentralityResult compute_closeness(const CsrGraph& g) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_t weights = csr_to_weights(g);
    igraph_vector_t result;
    igraph_vector_init(&result, 0);

    igraph_closeness(&graph, &result, NULL, NULL,
                     igraph_vss_all(), IGRAPH_OUT,
                     &weights, true);

    CentralityResult cr;
    cr.scores.resize(igraph_vector_size(&result));
    for (igraph_integer_t i = 0; i < igraph_vector_size(&result); i++) {
        cr.scores[i] = VECTOR(result)[i];
    }

    igraph_vector_destroy(&result);
    igraph_vector_destroy(&weights);
    igraph_destroy(&graph);
    return cr;
}

CommunityResult compute_louvain(const CsrGraph& g) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_t weights = csr_to_weights(g);
    igraph_vector_int_t membership;
    igraph_vector_int_init(&membership, 0);
    igraph_real_t modularity;

    igraph_community_multilevel(&graph, &weights,
                                1.0,  // resolution
                                &membership, NULL, &modularity);

    CommunityResult cr;
    cr.modularity = modularity;
    cr.membership.resize(igraph_vector_int_size(&membership));
    int64_t max_id = 0;
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(&membership); i++) {
        cr.membership[i] = VECTOR(membership)[i];
        if (cr.membership[i] > max_id) max_id = cr.membership[i];
    }
    cr.n_communities = max_id + 1;

    igraph_vector_int_destroy(&membership);
    igraph_vector_destroy(&weights);
    igraph_destroy(&graph);
    return cr;
}

CommunityResult compute_label_propagation(const CsrGraph& g) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_t weights = csr_to_weights(g);
    igraph_vector_int_t membership;
    igraph_vector_int_init(&membership, 0);
    igraph_real_t modularity;

    igraph_community_label_propagation(&graph, &membership,
                                       IGRAPH_ALL, &weights,
                                       NULL, NULL,
                                       IGRAPH_LPA_VARIANT_RAK);

    CommunityResult cr;
    cr.modularity = modularity;
    cr.membership.resize(igraph_vector_int_size(&membership));
    int64_t max_id = 0;
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(&membership); i++) {
        cr.membership[i] = VECTOR(membership)[i];
        if (cr.membership[i] > max_id) max_id = cr.membership[i];
    }
    cr.n_communities = max_id + 1;

    igraph_vector_int_destroy(&membership);
    igraph_vector_destroy(&weights);
    igraph_destroy(&graph);
    return cr;
}

CommunityResult compute_leiden(const CsrGraph& g, double resolution) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_t weights = csr_to_weights(g);
    igraph_vector_int_t membership;
    igraph_vector_int_init(&membership, 0);
    igraph_real_t quality;

    igraph_community_leiden(&graph, &weights, NULL,
                            resolution, 0.01, false,
                            -1,
                            &membership, NULL, &quality);

    CommunityResult cr;
    cr.modularity = quality;
    cr.membership.resize(igraph_vector_int_size(&membership));
    int64_t max_id = 0;
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(&membership); i++) {
        cr.membership[i] = VECTOR(membership)[i];
        if (cr.membership[i] > max_id) max_id = cr.membership[i];
    }
    cr.n_communities = max_id + 1;

    igraph_vector_int_destroy(&membership);
    igraph_vector_destroy(&weights);
    igraph_destroy(&graph);
    return cr;
}

SccResult compute_scc(const CsrGraph& g) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_int_t membership;
    igraph_vector_int_init(&membership, 0);
    igraph_integer_t n_comp;

    igraph_connected_components(&graph, &membership, NULL, &n_comp,
                                 IGRAPH_STRONG);

    SccResult result;
    result.n_components = n_comp;
    result.membership.resize(igraph_vector_int_size(&membership));
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(&membership); i++) {
        result.membership[i] = VECTOR(membership)[i];
    }

    igraph_vector_int_destroy(&membership);
    igraph_destroy(&graph);
    return result;
}

bool compute_is_acyclic(const CsrGraph& g) {
    igraph_t graph = csr_to_igraph(g);
    igraph_bool_t is_dag;
    igraph_is_dag(&graph, &is_dag);
    igraph_destroy(&graph);
    return is_dag;
}

std::vector<int64_t> compute_topological_sort(const CsrGraph& g) {
    igraph_t graph = csr_to_igraph(g);
    igraph_vector_int_t order;
    igraph_vector_int_init(&order, 0);

    igraph_topological_sorting(&graph, &order, IGRAPH_OUT);

    std::vector<int64_t> result(igraph_vector_int_size(&order));
    for (igraph_integer_t i = 0; i < igraph_vector_int_size(&order); i++) {
        result[i] = VECTOR(order)[i];
    }

    igraph_vector_int_destroy(&order);
    igraph_destroy(&graph);
    return result;
}

} // namespace grafi

// ═══════════════════════════════════════════════════════════════════════
// NIF exports via fine
// ═══════════════════════════════════════════════════════════════════════

// Helper: decode a list of int64 from Elixir
static std::vector<int64_t> decode_int_list(ErlNifEnv* env, ERL_NIF_TERM list) {
    unsigned len;
    enif_get_list_length(env, list, &len);
    std::vector<int64_t> result(len);
    ERL_NIF_TERM head, tail = list;
    for (unsigned i = 0; i < len; i++) {
        enif_get_list_cell(env, tail, &head, &tail);
        int64_t val;
        enif_get_int64(env, head, &val);
        result[i] = val;
    }
    return result;
}

// Helper: decode a list of doubles from Elixir
static std::vector<double> decode_float_list(ErlNifEnv* env, ERL_NIF_TERM list) {
    unsigned len;
    enif_get_list_length(env, list, &len);
    std::vector<double> result(len);
    ERL_NIF_TERM head, tail = list;
    for (unsigned i = 0; i < len; i++) {
        enif_get_list_cell(env, tail, &head, &tail);
        double val;
        enif_get_double(env, head, &val);
        result[i] = val;
    }
    return result;
}

// Helper: decode CSR graph from Elixir map
static grafi::CsrGraph decode_csr(ErlNifEnv* env, ERL_NIF_TERM map) {
    grafi::CsrGraph csr;
    ERL_NIF_TERM val;

    enif_get_map_value(env, map, enif_make_atom(env, "row_offsets"), &val);
    csr.row_offsets = decode_int_list(env, val);

    enif_get_map_value(env, map, enif_make_atom(env, "col_indices"), &val);
    csr.col_indices = decode_int_list(env, val);

    enif_get_map_value(env, map, enif_make_atom(env, "weights"), &val);
    csr.weights = decode_float_list(env, val);

    enif_get_map_value(env, map, enif_make_atom(env, "n_vertices"), &val);
    enif_get_int64(env, val, &csr.n_vertices);

    enif_get_map_value(env, map, enif_make_atom(env, "directed"), &val);
    char atom_buf[16];
    enif_get_atom(env, val, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1);
    csr.directed = (std::string(atom_buf) == "true");

    return csr;
}

// Helper: encode list of doubles
static ERL_NIF_TERM encode_float_list(ErlNifEnv* env, const std::vector<double>& v) {
    std::vector<ERL_NIF_TERM> terms(v.size());
    for (size_t i = 0; i < v.size(); i++) {
        terms[i] = enif_make_double(env, v[i]);
    }
    return enif_make_list_from_array(env, terms.data(), terms.size());
}

// Helper: encode list of int64
static ERL_NIF_TERM encode_int_list(ErlNifEnv* env, const std::vector<int64_t>& v) {
    std::vector<ERL_NIF_TERM> terms(v.size());
    for (size_t i = 0; i < v.size(); i++) {
        terms[i] = enif_make_int64(env, v[i]);
    }
    return enif_make_list_from_array(env, terms.data(), terms.size());
}

// ── NIF: PageRank ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_pagerank(ErlNifEnv* env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    double damping;
    int max_iter;
    enif_get_double(env, argv[1], &damping);
    enif_get_int(env, argv[2], &max_iter);

    auto result = grafi::compute_pagerank(csr, damping, max_iter);
    return encode_float_list(env, result.ranks);
}

// ── NIF: Dijkstra ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_dijkstra(ErlNifEnv* env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    int64_t source, target;
    enif_get_int64(env, argv[1], &source);
    enif_get_int64(env, argv[2], &target);

    auto result = grafi::compute_dijkstra(csr, source, target);

    if (result.found) {
        return enif_make_tuple3(env,
            enif_make_atom(env, "ok"),
            encode_int_list(env, result.path),
            enif_make_double(env, result.distance));
    } else {
        return enif_make_atom(env, "no_path");
    }
}

// ── NIF: Betweenness centrality ────────────────────────────────────────

static ERL_NIF_TERM nif_betweenness(ErlNifEnv* env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    auto result = grafi::compute_betweenness(csr);
    return encode_float_list(env, result.scores);
}

// ── NIF: Closeness centrality ──────────────────────────────────────────

static ERL_NIF_TERM nif_closeness(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    auto result = grafi::compute_closeness(csr);
    return encode_float_list(env, result.scores);
}

// ── NIF: Louvain community detection ───────────────────────────────────

static ERL_NIF_TERM nif_louvain(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    auto result = grafi::compute_louvain(csr);

    return enif_make_tuple3(env,
        encode_int_list(env, result.membership),
        enif_make_double(env, result.modularity),
        enif_make_int64(env, result.n_communities));
}

// ── NIF: Label propagation ─────────────────────────────────────────────

static ERL_NIF_TERM nif_label_propagation(ErlNifEnv* env, int argc,
                                           const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    auto result = grafi::compute_label_propagation(csr);

    return enif_make_tuple3(env,
        encode_int_list(env, result.membership),
        enif_make_double(env, result.modularity),
        enif_make_int64(env, result.n_communities));
}

// ── NIF: Leiden ─────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_leiden(ErlNifEnv* env, int argc,
                                const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    double resolution;
    enif_get_double(env, argv[1], &resolution);
    auto result = grafi::compute_leiden(csr, resolution);

    return enif_make_tuple3(env,
        encode_int_list(env, result.membership),
        enif_make_double(env, result.modularity),
        enif_make_int64(env, result.n_communities));
}

// ── NIF: Strongly connected components ─────────────────────────────────

static ERL_NIF_TERM nif_scc(ErlNifEnv* env, int argc,
                             const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    auto result = grafi::compute_scc(csr);

    return enif_make_tuple2(env,
        encode_int_list(env, result.membership),
        enif_make_int64(env, result.n_components));
}

// ── NIF: Is DAG? ───────────────────────────────────────────────────────

static ERL_NIF_TERM nif_is_acyclic(ErlNifEnv* env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    bool acyclic = grafi::compute_is_acyclic(csr);
    return enif_make_atom(env, acyclic ? "true" : "false");
}

// ── NIF: Topological sort ──────────────────────────────────────────────

static ERL_NIF_TERM nif_topological_sort(ErlNifEnv* env, int argc,
                                          const ERL_NIF_TERM argv[]) {
    auto csr = decode_csr(env, argv[0]);
    auto result = grafi::compute_topological_sort(csr);
    return encode_int_list(env, result);
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
};

ERL_NIF_INIT(Elixir.Grafi.NIF, nif_funcs, NULL, NULL, NULL, NULL)
