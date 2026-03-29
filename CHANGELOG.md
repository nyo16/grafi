# Changelog

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
