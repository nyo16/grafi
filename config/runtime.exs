import Config

# Runtime configuration for Grafi
#
# These settings can be overridden via environment variables:
#
#   GRAFI_NIF_THRESHOLD - vertex count above which algorithms dispatch to igraph
#   GRAFI_NIF_ENABLED   - set to "false" to force pure Elixir (no NIF dispatch)

config :grafi,
  nif_threshold: System.get_env("GRAFI_NIF_THRESHOLD", "500") |> String.to_integer(),
  nif_enabled: System.get_env("GRAFI_NIF_ENABLED", "true") == "true"
