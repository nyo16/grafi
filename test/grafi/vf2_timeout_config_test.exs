defmodule Grafi.VF2TimeoutConfigTest do
  # Exercises the `config :grafi, vf2_timeout:` path end to end. It mutates
  # global application env, so it must not run concurrently with the async
  # isomorphism tests.
  use ExUnit.Case, async: false

  alias Grafi.Algo.Isomorphism
  alias Grafi.Generators

  setup do
    previous = Application.fetch_env(:grafi, :vf2_timeout)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:grafi, :vf2_timeout, value)
        :error -> Application.delete_env(:grafi, :vf2_timeout)
      end
    end)
  end

  # The VF2 timeout fixture from `Grafi.EngineErrorsTest`: a dense host and a
  # K14 pattern take seconds to refute exhaustively.
  defp hard_instance,
    do:
      {Generators.erdos_renyi(40, 0.5, seed: 42, type: :undirected),
       Generators.complete(14, type: :undirected)}

  test "a finite config value bounds the search when :timeout is absent" do
    Application.put_env(:grafi, :vf2_timeout, 20)
    {host, pattern} = hard_instance()

    assert_raise Grafi.TimeoutError, ~r/20 ms/, fn ->
      Isomorphism.subgraph_isomorphic?(host, pattern, engine: :elixir)
    end
  end

  test "an explicit timeout: :infinity overrides the config" do
    # An invalid config value would raise if it were consulted.
    Application.put_env(:grafi, :vf2_timeout, :bogus)

    assert Isomorphism.subgraph_isomorphic?(
             Generators.complete(4, type: :undirected),
             Generators.complete(3, type: :undirected),
             engine: :elixir,
             timeout: :infinity
           ) == true
  end

  test "an invalid config value raises ArgumentError when :timeout is absent" do
    Application.put_env(:grafi, :vf2_timeout, :bogus)

    assert_raise ArgumentError, ~r/vf2_timeout/, fn ->
      Isomorphism.subgraph_isomorphic?(
        Generators.complete(4, type: :undirected),
        Generators.complete(3, type: :undirected),
        engine: :elixir
      )
    end
  end
end
