# dag_critical_path.exs — critical path + layers on a build pipeline DAG.
# Edge weights are task durations (minutes).
# Run with: mix run examples/dag_critical_path.exs

alias Grafi.DAG

pipeline =
  DAG.new()
  |> DAG.add_edges([
    {"checkout", "fetch_deps", weight: 2.0},
    {"checkout", "lint", weight: 1.0},
    {"fetch_deps", "compile", weight: 8.0},
    {"compile", "unit_tests", weight: 5.0},
    {"compile", "type_check", weight: 4.0},
    {"unit_tests", "integration_tests", weight: 12.0},
    {"type_check", "integration_tests", weight: 0.5},
    {"lint", "integration_tests", weight: 0.5},
    {"integration_tests", "package", weight: 3.0},
    {"package", "deploy", weight: 6.0}
  ])

IO.puts("Build pipeline: #{Grafi.num_vertices(DAG.to_graph(pipeline))} tasks\n")

{:ok, order} = DAG.topological_sort(pipeline)
IO.puts("Topological order:")
IO.puts("  " <> Enum.join(order, " → "))
IO.puts("")

layers = DAG.layers(pipeline)
IO.puts("Layers (tasks that can run in parallel):")

layers
|> Enum.sort_by(fn {l, _} -> l end)
|> Enum.each(fn {layer, tasks} ->
  IO.puts("  layer #{layer}: #{Enum.join(tasks, ", ")}")
end)

IO.puts("")

{path, total} = DAG.critical_path(pipeline)
IO.puts("Critical path (#{total} min total):")
IO.puts("  " <> Enum.join(path, " → "))
