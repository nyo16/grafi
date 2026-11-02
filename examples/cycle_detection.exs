# cycle_detection.exs — detect cycles, find one, then list all SCCs.
# Models a small package dependency graph with a deliberate circular dep.
# Run with: mix run examples/cycle_detection.exs

# logger needs config; config needs runtime; runtime needs logger → cycle.
deps = [
  {"app", "http_client"},
  {"app", "logger"},
  {"http_client", "tls"},
  {"http_client", "logger"},
  {"logger", "config"},
  {"config", "runtime"},
  {"runtime", "logger"},
  {"tls", "crypto"}
]

graph =
  Grafi.new()
  |> Grafi.add_edges(deps)

IO.puts(
  "Package dep graph: #{Grafi.num_vertices(graph)} packages, #{Grafi.num_edges(graph)} deps\n"
)

IO.puts("Has cycle? #{Grafi.has_cycle?(graph)}")

case Grafi.Algo.Cycles.find_cycle(graph) do
  {:ok, cycle} ->
    IO.puts("One cycle: " <> Enum.join(cycle, " → "))

  {:error, :no_cycle} ->
    IO.puts("No cycle.")
end

IO.puts("")

sccs = Grafi.Algo.Cycles.strongly_connected_components(graph)

IO.puts("Strongly connected components (#{length(sccs)}):")

sccs
|> Enum.with_index(1)
|> Enum.each(fn {scc, i} ->
  marker = if length(scc) > 1, do: " (cyclic)", else: ""
  IO.puts("  #{i}: #{Enum.join(Enum.sort(scc), ", ")}#{marker}")
end)
