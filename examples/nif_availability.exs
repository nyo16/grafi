# nif_availability.exs — report NIF status and which algos dispatch to it.
# Dispatch is by graph size: algorithms above :nif_threshold (default 500)
# use the NIF if available, otherwise they run in pure Elixir.
# Run with: mix run examples/nif_availability.exs

available? = Grafi.NIF.available?()
threshold = Application.get_env(:grafi, :nif_threshold, 500)

IO.puts("Grafi.NIF.available?  => #{available?}")
IO.puts("nif_threshold          => #{threshold} vertices")
IO.puts("")

if available? do
  IO.puts("igraph NIF is loaded. Algorithms above the threshold dispatch to C.")
else
  IO.puts("igraph NIF NOT loaded. All algorithms run in pure Elixir.")
  IO.puts("Install igraph (see README) and rebuild to enable NIF acceleration.")
end

IO.puts("")
IO.puts("Per-algorithm dispatch (V = num_vertices):\n")

table = [
  {"Dijkstra (shortest_path)", "NIF if V > #{threshold} and NIF available, else Elixir"},
  {"PageRank", "NIF (PRPACK) if V > #{threshold} and NIF available, else Elixir"},
  {"Betweenness", "NIF if V > #{threshold} and NIF available, else Brandes/Elixir"},
  {"Closeness", "NIF if V > #{threshold} and NIF available, else Elixir"},
  {"Louvain / Leiden", "NIF only — no Elixir fallback"},
  {"Label propagation", "NIF if available, else label_propagation_simple/1"},
  {"BFS / DFS / cycles / DAG", "always pure Elixir"}
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
