# Changelog

## [Unreleased]

- Fixed igraph 1.0.x and OTP 28 compatibility in C++ NIF
- Replaced throw-for-flow-control with explicit conditionals
- Replaced O(n²) list appends with `:queue` and prepend+reverse
- Made NIF threshold runtime-configurable via Application config
- Added Credo, Dialyzer, and GitHub Actions CI
- Added `runtime.exs` for environment-based configuration
- Expanded test suite with edge cases, JSON round-trip, and property-based tests
- Added `@doc` annotations to all public functions

## v0.1.0

- Initial release
- Core graph struct (directed, undirected, weighted, labelled)
- DAG with cycle prevention, topological sort, layers, critical path
- Traversals: BFS, DFS as lazy streams
- Shortest path: Dijkstra, Bellman-Ford, A*
- Centrality: PageRank, betweenness (Brandes), closeness, degree
- Cycles: detection, finding, SCC (Tarjan), condensation
- Community detection: Louvain, Leiden, label propagation (via igraph NIF)
- Serialization: DOT, JSON
- igraph C++ NIF engine via fine with graceful fallback
