# Tests tagged :nif force `engine: :nif`; they run only when the NIF is loaded
# and NIF dispatch is enabled. Tests tagged :no_nif check the fallback
# errors and run only when it is not (e.g. GRAFI_NIF_ENABLED=false).
# Tests tagged :graphviz need a real Graphviz `dot` in PATH.
# Tests tagged :slow are scaling-ratio checks (4x input < 8x time, best of 3),
# not wall-clock budgets; they are excluded by default
# (parallel load makes them flaky) and CI runs them alone with
# `mix test --only slow --max-cases 1`.
exclude = if Grafi.NIF.available?(), do: [:no_nif], else: [:nif]
exclude = exclude ++ [:slow, graphviz: not Grafi.Viz.graphviz_available?()]

ExUnit.start(exclude: exclude)
