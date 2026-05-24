# community_detection.exs — find clusters in a small social graph.
# Tries Louvain (igraph NIF) first; falls back to pure-Elixir label propagation.
# Run with: mix run examples/community_detection.exs

# Two cliques (a friend group and a work group) linked by one bridge.
friendships = [
  # Friend group
  {"Alice", "Bob"},
  {"Alice", "Carol"},
  {"Bob", "Carol"},
  {"Carol", "Dan"},
  {"Bob", "Dan"},
  # Work group
  {"Eve", "Frank"},
  {"Eve", "Grace"},
  {"Frank", "Grace"},
  {"Grace", "Henry"},
  {"Frank", "Henry"},
  # Bridge between the two groups
  {"Dan", "Eve"}
]

graph =
  Grafi.new(type: :undirected)
  |> Grafi.add_edges(friendships)

IO.puts(
  "Social graph: #{Grafi.num_vertices(graph)} people, #{Grafi.num_edges(graph)} friendships\n"
)

result =
  case Grafi.louvain(graph) do
    {:ok, r} ->
      IO.puts("Algorithm: Louvain (igraph NIF)")
      r

    {:error, :nif_not_available} ->
      IO.puts("Algorithm: pure-Elixir label propagation (NIF unavailable)")
      Grafi.Algo.Community.label_propagation_simple(graph)
  end

IO.puts("Modularity: #{:io_lib.format("~.4f", [result.modularity])}")
IO.puts("Communities found: #{result.n_communities}\n")

result.communities
|> Enum.sort_by(fn {id, _} -> id end)
|> Enum.each(fn {id, members} ->
  IO.puts("  Community #{id}: #{Enum.join(Enum.sort(members), ", ")}")
end)
