defmodule Grafi.MixProject do
  use Mix.Project

  # Between releases this carries a `-dev` suffix: elixir_make then always
  # builds from source instead of fetching (stale) published artefacts. See
  # RELEASING.md.
  @version "0.1.0-dev"
  @source_url "https://github.com/nyo16/grafi"

  def project do
    [
      app: :grafi,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:unmatched_returns, :error_handling]
      ],
      # Floor for the merged three-engine-mode coverage in CI (92.7% when
      # set): rounded down to a multiple of 5. Inspect impls and the test
      # generators are not measured; the NIF stub bodies are.
      test_coverage: [
        summary: [threshold: 90],
        ignore_modules: [~r/^Inspect\./, Grafi.Test.Generators]
      ],
      # The precompiled NIF statically links igraph and is GPL-3.0-or-later,
      # so a consumer downloads it only after opting in, in their
      # config/config.exs:
      #
      #     config :grafi, precompiled_nif: true
      #
      # Otherwise c_src is compiled against a local igraph, or Grafi runs in
      # pure Elixir without one. A git checkout (contributors, CI, git deps)
      # always compiles c_src. `.git` is a file in worktrees and submodules,
      # hence `exists?`; not `File.cwd!()`, since Mix compiles a dependency
      # from inside its own directory. The consumer's config is loaded before
      # a dependency's project/0 is evaluated.
      make_force_build: force_build?(),
      make_clean: ["clean"],
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url: "#{@source_url}/releases/download/v#{@version}/@{artefact_filename}",
      make_precompiler_filename: "grafi_nif",
      make_precompiler_priv_paths: ["grafi_nif.*"],
      # NIF 2.17 is OTP 26-28; OTP 29 (NIF 2.18) loads the 2.17 artefact via
      # elixir_make's same-major fallback. Release builds run on OTP 28.
      make_precompiler_nif_versions: [versions: ["2.17"]],
      make_env: fn -> %{"FINE_INCLUDE_DIR" => Fine.include_dir()} end,
      cc_precompiler: cc_precompiler(),
      description:
        "High-performance graph library for Elixir — γραφή. Apache-2.0; the optional " <>
          "precompiled NIF (opt-in) statically links igraph and is GPL-3.0-or-later (see NOTICE).",
      package: package(),
      docs: docs(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [bench: :bench]]
  end

  defp force_build? do
    File.exists?(Path.join(__DIR__, ".git")) or
      Application.get_env(:grafi, :precompiled_nif, false) != true
  end

  def application do
    [
      extra_applications: [:logger],
      # Defaults duplicated as module attributes in Grafi.NIF (nif_threshold,
      # nif_enabled) and Grafi.Algo.Isomorphism (vf2_timeout); keep in sync.
      env: [nif_threshold: 500, nif_enabled: true, vf2_timeout: :infinity]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # C++ NIF bridge (elixir-nx); build-time only (headers).
      {:fine, "~> 0.1.6", runtime: false},
      {:elixir_make, "~> 0.10", runtime: false},
      # Not optional: consumers need it to fetch artefacts or build from source.
      {:cc_precompiler, "~> 0.1.11", runtime: false},
      # Optional: Livebook renders a Grafi.Graph as Mermaid when present.
      {:kino, "~> 0.14", optional: true},

      # Dev / test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:benchee, "~> 1.3", only: :bench}
    ]
  end

  # The targets with precompiled artefacts (built by release.yml's scripts).
  # cc_precompiler uses this list on the consumer side to pick the artefact.
  #
  # `only_listed_targets` stays off for consumers: on an unlisted target
  # cc_precompiler then returns `:compile` (build from source, or pure Elixir
  # without igraph) instead of `:ignore` (no NIF at all). It is on only for a
  # local `CC_PRECOMPILER_PRECOMPILE_ONLY_LOCAL=true mix elixir_make.precompile`.
  defp cc_precompiler do
    [
      only_listed_targets: System.get_env("CC_PRECOMPILER_PRECOMPILE_ONLY_LOCAL") == "true",
      compilers: %{
        {:unix, :linux} => %{
          "x86_64-linux-gnu" => "x86_64-linux-gnu-",
          "aarch64-linux-gnu" => "aarch64-linux-gnu-"
        },
        {:unix, :darwin} => %{
          "x86_64-apple-darwin" =>
            {"gcc", "g++", "<%= cc %> -arch x86_64", "<%= cxx %> -arch x86_64"},
          "aarch64-apple-darwin" =>
            {"gcc", "g++", "<%= cc %> -arch arm64", "<%= cxx %> -arch arm64"}
        }
      }
    ]
  end

  defp package do
    [
      name: "grafi",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib c_src Makefile checksum.exs .formatter.exs mix.exs README.md LICENSE NOTICE
           LICENSES CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Grafi",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE", "NOTICE"],
      # Every public module must land in a group; check the "Modules" sidebar
      # after `mix docs` when adding one.
      groups_for_modules: [
        Core: [Grafi, Grafi.Graph, Grafi.DAG, Grafi.Edge, Grafi.Generators, Grafi.UnionFind],
        Algorithms: ~r/^Grafi\.Algo\./,
        Serialization: ~r/^Grafi\.Serialize\./,
        "Layout & Visualization": [Grafi.Layout, Grafi.Viz, Grafi.Kino],
        "Native Engine & Errors": [
          Grafi.NIF,
          Grafi.NIFError,
          Grafi.TimeoutError,
          Grafi.CycleError,
          Grafi.DisconnectedError
        ]
      ]
    ]
  end

  defp aliases do
    [bench: "run bench/run.exs"]
  end
end
