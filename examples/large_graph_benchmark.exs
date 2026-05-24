# large_graph_benchmark.exs — timing on a synthetic ~5k-vertex graph.
# No Benchee dependency; uses :timer.tc for simple wall-clock numbers.
# Run with: mix run examples/large_graph_benchmark.exs

:rand.seed(:exsss, {1, 2, 3})

n_vertices = 5_000
n_edges = 20_000

IO.puts("Building synthetic graph: #{n_vertices} vertices, #{n_edges} random edges...")

{build_us, graph} =
  :timer.tc(fn ->
    vertices = Enum.to_list(0..(n_vertices - 1))

    edges =
      for _ <- 1..n_edges do
        a = :rand.uniform(n_vertices) - 1
        b = :rand.uniform(n_vertices) - 1
        {a, b, weight: :rand.uniform() * 10.0}
      end

    Grafi.new()
    |> Grafi.add_vertices(vertices)
    |> Grafi.add_edges(edges)
  end)

IO.puts("  build:           #{build_us} µs (#{Float.round(build_us / 1_000, 1)} ms)")
IO.puts("  NIF available?:  #{Grafi.NIF.available?()}")
IO.puts("")

# Pick a high-degree-ish source so shortest_path has something to chew on.
source = 0
target = n_vertices - 1

{sp_us, sp_result} =
  :timer.tc(fn -> Grafi.shortest_path(graph, source, target) end)

case sp_result do
  {:ok, {path, dist}} ->
    IO.puts("shortest_path #{source} → #{target}:")
    IO.puts("  time:   #{sp_us} µs (#{Float.round(sp_us / 1_000, 1)} ms)")
    IO.puts("  hops:   #{length(path) - 1}")
    IO.puts("  dist:   #{Float.round(dist, 3)}")

  :no_path ->
    IO.puts("shortest_path #{source} → #{target}: :no_path (#{sp_us} µs)")
end

IO.puts("")

{pr_us, ranks} =
  :timer.tc(fn -> Grafi.pagerank(graph, iterations: 30) end)

{top_v, top_r} = Enum.max_by(ranks, fn {_, r} -> r end)

IO.puts("pagerank (30 iterations):")
IO.puts("  time:        #{pr_us} µs (#{Float.round(pr_us / 1_000, 1)} ms)")
IO.puts("  top vertex:  #{top_v} (#{Float.round(top_r, 6)})")
