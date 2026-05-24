# pagerank.exs — PageRank over a small academic citation network.
# Edges go from citing paper → cited paper.
# Run with: mix run examples/pagerank.exs

citations = [
  {"Shannon1948", "Turing1936"},
  {"Cook1971", "Turing1936"},
  {"Karp1972", "Cook1971"},
  {"Karp1972", "Turing1936"},
  {"Dijkstra1959", "Turing1936"},
  {"Knuth1968", "Dijkstra1959"},
  {"Knuth1968", "Shannon1948"},
  {"Cormen2009", "Dijkstra1959"},
  {"Cormen2009", "Karp1972"},
  {"Cormen2009", "Knuth1968"}
]

graph =
  Grafi.new()
  |> Grafi.add_edges(citations)

ranks = Grafi.pagerank(graph)

IO.puts("PageRank (#{Grafi.num_vertices(graph)} papers, #{Grafi.num_edges(graph)} citations):\n")

ranks
|> Enum.sort_by(fn {_paper, score} -> score end, :desc)
|> Enum.each(fn {paper, score} ->
  IO.puts("  #{:io_lib.format("~.4f", [score])}  #{paper}")
end)
