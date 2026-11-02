# Tests tagged :nif force `engine: :nif`; they run only when the NIF is loaded
# and NIF dispatch is enabled. Tests tagged :no_nif check the fallback
# errors and run only when it is not (e.g. GRAFI_NIF_ENABLED=false).
exclude = if Grafi.NIF.available?(), do: [:no_nif], else: [:nif]

ExUnit.start(exclude: exclude)
