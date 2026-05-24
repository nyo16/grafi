defmodule Grafi.Kino do
  @moduledoc """
  Livebook / Kino integration for Grafi graphs.

  This module produces Markdown strings that wrap a Mermaid graph block,
  ready to feed into `Kino.Markdown.new/1`. Grafi does **not** declare
  `:kino` as a dependency — bring your own. The output is plain text, so
  no compile-time tricks are needed.

  ## Usage in a Livebook

      Mix.install([
        {:grafi, "~> 0.1"},
        {:kino, "~> 0.12"}
      ])

      g =
        Grafi.new()
        |> Grafi.add_edges([
          {:athens, :sparta, weight: 210.0},
          {:athens, :corinth, weight: 80.0}
        ])

      g
      |> Grafi.Kino.to_kino()
      |> Kino.Markdown.new()

  ## Options

  All options are forwarded to `Grafi.Serialize.Mermaid.to_mermaid/2`,
  including `:direction`, `:graph_type`, `:weights`, and `:vertex_label`.
  """

  alias Grafi.Graph
  alias Grafi.Serialize.Mermaid

  @doc """
  Renders the graph as a Markdown string with a fenced ` ```mermaid` block.

  Pipe the result into `Kino.Markdown.new/1` to embed it in a Livebook
  cell. The output is also valid GitHub-flavoured Markdown and renders
  natively on GitHub, GitLab, and Notion.

  ## Examples

      iex> md = Grafi.Graph.new()
      ...>   |> Grafi.Graph.add_edge(:a, :b)
      ...>   |> Grafi.Kino.to_kino()
      iex> String.starts_with?(md, "```mermaid\\n")
      true
      iex> String.ends_with?(md, "\\n```")
      true
      iex> md =~ "flowchart"
      true
  """
  @spec to_kino(Graph.t(), keyword()) :: String.t()
  def to_kino(%Graph{} = g, opts \\ []) do
    mermaid = Mermaid.to_mermaid(g, opts)
    "```mermaid\n" <> mermaid <> "\n```"
  end

  @doc """
  Alias for `to_kino/2`. Returns the Markdown-fenced Mermaid block as a
  string.
  """
  @spec to_mermaid_block(Graph.t(), keyword()) :: String.t()
  def to_mermaid_block(%Graph{} = g, opts \\ []), do: to_kino(g, opts)
end
