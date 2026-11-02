# shortest_path.exs — Dijkstra on a small road network.
# Run with: mix run examples/shortest_path.exs

roads = [
  {"Athens", "Corinth", weight: 80.0},
  {"Athens", "Thebes", weight: 90.0},
  {"Corinth", "Sparta", weight: 130.0},
  {"Corinth", "Olympia", weight: 150.0},
  {"Thebes", "Delphi", weight: 110.0},
  {"Delphi", "Olympia", weight: 220.0},
  {"Sparta", "Olympia", weight: 100.0},
  {"Sparta", "Pylos", weight: 95.0},
  # "Crete" is an island — unreachable by road from the mainland.
  {"Heraklion", "Chania", weight: 140.0}
]

graph =
  Grafi.new(type: :undirected)
  |> Grafi.add_edges(roads)

IO.puts("Road network: #{Grafi.num_vertices(graph)} cities, #{Grafi.num_edges(graph)} roads\n")

case Grafi.shortest_path(graph, "Athens", "Olympia") do
  {:ok, {path, cost}} ->
    IO.puts("Shortest route Athens → Olympia:")
    IO.puts("  " <> Enum.join(path, " → "))
    IO.puts("  total: #{cost} km")

  {:error, :no_path} ->
    IO.puts("No route from Athens to Olympia.")
end

IO.puts("")

case Grafi.shortest_path(graph, "Athens", "Heraklion") do
  {:ok, {path, cost}} ->
    IO.puts("Athens → Heraklion: #{Enum.join(path, " → ")} (#{cost} km)")

  {:error, :no_path} ->
    IO.puts("Athens → Heraklion: no path (Crete is an island)")
end
