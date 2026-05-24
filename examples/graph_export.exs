# graph_export.exs — export a small graph to DOT and JSON.
# Writes a .dot file to /tmp and prints a hint for rendering with Graphviz.
# Run with: mix run examples/graph_export.exs

graph =
  Grafi.new()
  |> Grafi.add_edges([
    {"client", "api_gateway", weight: 1.0, label: "HTTPS"},
    {"api_gateway", "auth_service", weight: 1.0, label: "gRPC"},
    {"api_gateway", "orders_service", weight: 1.0, label: "gRPC"},
    {"orders_service", "postgres", weight: 1.0, label: "SQL"},
    {"orders_service", "redis", weight: 1.0, label: "cache"},
    {"auth_service", "postgres", weight: 1.0, label: "SQL"}
  ])

dot = Grafi.to_dot(graph, name: "services")
json = Grafi.to_json(graph)

IO.puts("=== DOT ===\n")
IO.puts(dot)

IO.puts("\n=== JSON ===\n")
IO.puts(json)

dot_path = "/tmp/grafi_example.dot"
File.write!(dot_path, dot)
IO.puts("\nWrote #{dot_path}")
IO.puts("Render to PNG with:")
IO.puts("  dot -Tpng #{dot_path} -o /tmp/grafi_example.png")
