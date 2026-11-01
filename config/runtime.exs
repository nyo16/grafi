import Config

# Dev/test/CI convenience for working on grafi itself. Config files only
# apply to the top-level project, so this file has no effect when grafi is a
# dependency; the defaults then come from the `:grafi` application env in
# mix.exs (`nif_threshold: 500`, `nif_enabled: true`).
#
#   GRAFI_NIF_THRESHOLD - vertex count above which `engine: :auto` uses igraph
#   GRAFI_NIF_ENABLED   - set to "false" to disable NIF dispatch entirely

config :grafi,
  nif_threshold: System.get_env("GRAFI_NIF_THRESHOLD", "500") |> String.to_integer(),
  nif_enabled: System.get_env("GRAFI_NIF_ENABLED", "true") == "true"
