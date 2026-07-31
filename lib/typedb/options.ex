defmodule TypeDB.Options do
  @moduledoc """
  Transaction and query options, and their translation to the HTTP wire format.

  ## Transaction options

    * `:transaction_timeout_millis` — how long the server keeps an idle
      transaction alive before killing it. The driver also uses this as the
      ceiling for how long it waits on transaction requests.
    * `:schema_lock_acquire_timeout_millis` — how long a `schema` transaction
      waits for the exclusive schema lock.

  ## Query options

    * `:include_instance_types` — attach the type to every returned instance.
      Costs an extra type lookup per concept; turn it off for hot read paths
      where you already know the shape.
    * `:answer_count_limit` — cap the number of answers TypeDB materialises. The
      HTTP API is not streaming, so this is your protection against a `match`
      that matches the whole database. Exceeding it produces a `warning` on the
      answer rather than an error.
    * `:include_query_structure` — return the analysed pipeline structure
      alongside the rows, and populate `involved_blocks` on each row.

  Options are accepted as plain keyword lists everywhere in the public API;
  building these structs by hand is optional.
  """

  defmodule Transaction do
    @moduledoc "Transaction options. See `TypeDB.Options`."

    @type t :: %__MODULE__{
            transaction_timeout_millis: pos_integer() | nil,
            schema_lock_acquire_timeout_millis: pos_integer() | nil
          }

    defstruct [:transaction_timeout_millis, :schema_lock_acquire_timeout_millis]
  end

  defmodule Query do
    @moduledoc "Query options. See `TypeDB.Options`."

    @type t :: %__MODULE__{
            include_instance_types: boolean() | nil,
            answer_count_limit: pos_integer() | nil,
            include_query_structure: boolean() | nil
          }

    defstruct [:include_instance_types, :answer_count_limit, :include_query_structure]
  end

  @transaction_keys [:transaction_timeout_millis, :schema_lock_acquire_timeout_millis]
  @query_keys [:include_instance_types, :answer_count_limit, :include_query_structure]

  @doc """
  Extracts transaction options from a keyword list, returning the wire payload or
  `nil` when none were given.
  """
  @spec transaction_payload(keyword() | Transaction.t() | nil) :: map() | nil
  def transaction_payload(nil), do: nil
  def transaction_payload(%Transaction{} = options), do: encode(Map.from_struct(options), @transaction_keys)

  def transaction_payload(opts) when is_list(opts),
    do: opts |> Keyword.take(@transaction_keys) |> Map.new() |> encode(@transaction_keys)

  @doc """
  Extracts query options from a keyword list, returning the wire payload or `nil`
  when none were given.
  """
  @spec query_payload(keyword() | Query.t() | nil) :: map() | nil
  def query_payload(nil), do: nil
  def query_payload(%Query{} = options), do: encode(Map.from_struct(options), @query_keys)

  def query_payload(opts) when is_list(opts),
    do: opts |> Keyword.take(@query_keys) |> Map.new() |> encode(@query_keys)

  @doc false
  @spec transaction_keys() :: [atom()]
  def transaction_keys, do: @transaction_keys

  @doc false
  @spec query_keys() :: [atom()]
  def query_keys, do: @query_keys

  defp encode(map, keys) do
    # `false` is a meaningful value here, so filter on presence, not truthiness.
    payload =
      for key <- keys, (value = Map.get(map, key)) != nil, into: %{} do
        {camelize(key), value}
      end

    if map_size(payload) == 0, do: nil, else: payload
  end

  defp camelize(key) do
    [first | rest] = key |> Atom.to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end
end
