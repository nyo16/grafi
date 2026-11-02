# nif_availability.exs — report NIF status and which algos dispatch to it.
# With the default `engine: :auto`, most algorithms use the NIF above
# :nif_threshold (default 500) when it is available, and pure Elixir otherwise.
# Pass `engine: :nif` or `engine: :elixir` to force one.
# Run with: mix run examples/nif_availability.exs

available? = Grafi.NIF.available?()
threshold = Application.fetch_env!(:grafi, :nif_threshold)

IO.puts("Grafi.NIF.available?  => #{available?}")
IO.puts("nif_threshold          => #{threshold} vertices")
IO.puts("")

if available? do
  IO.puts("igraph NIF is loaded. Algorithms above the threshold dispatch to C.")
else
  IO.puts("igraph NIF NOT loaded (or nif_enabled: false). All algorithms run in pure Elixir.")
  IO.puts("Install igraph (see README) and rebuild to enable NIF acceleration.")
end

IO.puts("")
IO.puts("Per-algorithm dispatch with engine: :auto (V = num_vertices):\n")

table = [
  {"Dijkstra (shortest_path)", "NIF if V > #{threshold} and NIF available, else Elixir"},
  {"PageRank", "NIF (PRPACK) if V > #{threshold} and NIF available, else Elixir"},
  {"Betweenness / closeness", "NIF if V > #{threshold} and NIF available, else Elixir"},
  {"SCC / topological sort", "NIF if V > #{threshold} and NIF available, else Elixir"},
  {"Isomorphism (VF2)", "NIF whenever available, else Elixir backtracking"},
  {"Louvain / Leiden / LPA", "NIF only — {:error, :nif_not_available} without it"},
  {"BFS / DFS / cycle detection", "always pure Elixir"}
]

Enum.each(table, fn {algo, dispatch} ->
  IO.puts("  #{String.pad_trailing(algo, 28)} #{dispatch}")
end)

# Demonstrate a small graph: stays in Elixir regardless of NIF status.
small = Grafi.new() |> Grafi.add_edges([{"a", "b"}, {"b", "c"}, {"c", "a"}])
IO.puts("")
IO.puts("Sample run on a 3-vertex graph (always Elixir path):")
IO.inspect(Grafi.pagerank(small), label: "  pagerank")
IO.inspect(Grafi.shortest_path(small, "a", "c"), label: "  shortest_path")
