defmodule Grafi.MixProject do
  use Mix.Project

  @version "0.1.0"
  # TODO: Replace with your actual GitHub URL before publishing to Hex
  @source_url "https://github.com/nmaroulis/grafi"

  def project do
    [
      app: :grafi,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ],
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url: "#{@source_url}/releases/download/v#{@version}/@{artefact_filename}",
      description: "High-performance graph library for Elixir — γραφή",
      package: package(),
      docs: docs(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [bench: :bench]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # C++ NIF bridge (elixir-nx)
      {:fine, "~> 0.1"},
      {:elixir_make, "~> 0.8", runtime: false},
      {:cc_precompiler, "~> 0.1", runtime: false, optional: true},

      # Dev / test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:benchee, "~> 1.3", only: :bench},

      # Optional serialization
      {:jason, "~> 1.4", optional: true}
    ]
  end

  defp package do
    [
      name: "grafi",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib c_src Makefile checksum-*.exs .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Grafi",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
      groups_for_modules: [
        Core: [Grafi.Graph, Grafi.DAG, Grafi.Edge],
        Algorithms: [
          Grafi.Algo.Traversal,
          Grafi.Algo.ShortestPath,
          Grafi.Algo.Centrality,
          Grafi.Algo.Community,
          Grafi.Algo.Cycles
        ],
        Serialization: [
          Grafi.Serialize.DOT,
          Grafi.Serialize.JSON
        ],
        "NIF Engine": [Grafi.NIF]
      ]
    ]
  end

  defp aliases do
    [bench: "run bench/run.exs"]
  end
end
