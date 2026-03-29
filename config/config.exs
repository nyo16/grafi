import Config

# Grafi configuration
#
# Set the NIF threshold (vertex count above which algorithms dispatch to igraph):
#   config :grafi, nif_threshold: 500
#
# Disable NIF entirely (always use pure Elixir):
#   config :grafi, nif_enabled: false

config :grafi,
  nif_threshold: 500,
  nif_enabled: true
