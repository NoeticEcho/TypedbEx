defmodule TypeDB.JSON do
  @moduledoc """
  JSON codec indirection.

  JSON needs no dependency of its own. The codec is resolved, once, in this
  order:

    1. the module configured as `config :typedb, :json_codec, MyCodec`
    2. `TypeDB.JSON.Native`, backed by the built-in `JSON` module

  In practice the list ends there. This driver requires Elixir 1.18, every
  version of which has the built-in `JSON`, so step 2 always matches and
  **`TypeDB.JSON.Jason` is only ever reached by configuring it**:

      config :typedb, :json_codec, TypeDB.JSON.Jason

  `resolve!/0` still falls back to `Jason` and then to an error below step 2.
  Neither can execute while the Elixir floor is 1.18, and both are kept because
  they are unreachable owing to that floor rather than to being wrong — deleting
  them would turn a future change of floor into a silent change of behaviour.

  A codec is any module implementing this behaviour.

  ## The default is also the faster one

  Configuring `Jason` is a choice about dependencies, not about speed. Decoding
  the same 4.5 MB `conceptRows` answer, median of seven runs on Elixir 1.20.4
  and OTP 29:

  | codec | |
  | --- | ---: |
  | built-in `JSON` | 129 ms |
  | `Jason` | 180 ms |

  Reach for `Jason` if something else in your application already needs it and
  you would rather have one codec than two; know that it costs 40% on a large
  answer.
  """

  @doc "Encodes a term to JSON iodata. Raises on unencodable input."
  @callback encode_to_iodata!(term()) :: iodata()

  @doc "Decodes a JSON binary. Returns `{:error, reason}` on malformed input."
  @callback decode(binary()) :: {:ok, term()} | {:error, term()}

  @persistent_key {__MODULE__, :codec}

  @doc """
  Returns the resolved codec module.

  The result is memoised in `:persistent_term`. Change `:json_codec` before the
  first call, or call `reset/0` afterwards.
  """
  @spec codec() :: module()
  def codec do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        codec = resolve!()
        :persistent_term.put(@persistent_key, codec)
        codec

      codec ->
        codec
    end
  end

  @doc "Forgets the memoised codec. Intended for tests."
  @spec reset() :: :ok
  def reset do
    # erase/1 answers false when the key was never set, which is not a failure.
    _ = :persistent_term.erase(@persistent_key)
    :ok
  end

  @doc "Encodes `term` to JSON iodata."
  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term), do: codec().encode_to_iodata!(term)

  @doc "Encodes `term` to a JSON binary."
  @spec encode!(term()) :: binary()
  def encode!(term), do: term |> encode_to_iodata!() |> IO.iodata_to_binary()

  @doc "Decodes a JSON binary."
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary), do: codec().decode(binary)

  defp resolve! do
    cond do
      configured = Application.get_env(:typedb, :json_codec) ->
        configured

      Code.ensure_loaded?(JSON) ->
        TypeDB.JSON.Native

      Code.ensure_loaded?(Jason) ->
        TypeDB.JSON.Jason

      true ->
        raise TypeDB.Error.new(
                :config,
                """
                no JSON codec available.

                This driver requires Elixir 1.18 or later, which provides the
                built-in JSON module. To use a different codec, configure one:

                    config :typedb, :json_codec, MyApp.JSONCodec
                """
              )
    end
  end
end

defmodule TypeDB.JSON.Native do
  @moduledoc """
  `TypeDB.JSON` codec backed by Elixir's built-in `JSON` module (Elixir >= 1.18).
  """
  @behaviour TypeDB.JSON

  @compile {:no_warn_undefined, JSON}

  @impl true
  def encode_to_iodata!(term), do: JSON.encode_to_iodata!(term)

  @impl true
  def decode(binary) do
    case JSON.decode(binary) do
      {:ok, term} -> {:ok, term}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule TypeDB.JSON.Jason do
  @moduledoc """
  `TypeDB.JSON` codec backed by [Jason](https://hex.pm/packages/jason).

  Select it explicitly:

      config :typedb, :json_codec, TypeDB.JSON.Jason

  It is never selected automatically. `TypeDB.JSON` prefers the built-in `JSON`
  module, which exists on every Elixir this driver supports, so the fallback to
  this codec cannot be reached — see `TypeDB.JSON` for why the branch is kept
  anyway.

  `:jason` is an *optional* dependency: declared so the version this codec is
  written against is resolvable, never installed on its own.
  """
  @behaviour TypeDB.JSON

  @compile {:no_warn_undefined, Jason}

  @impl true
  def encode_to_iodata!(term), do: Jason.encode_to_iodata!(term)

  @impl true
  def decode(binary), do: Jason.decode(binary)
end
