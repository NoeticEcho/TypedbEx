defmodule TypeDB.Options do
  @moduledoc """
  Transaction and query options, and their translation to the HTTP wire format.

  You do not normally call anything here. Pass these as ordinary keyword options
  to `TypeDB.query/4`, `TypeDB.Transaction.open/4` or
  `TypeDB.Transaction.query/3`, mixed in with everything else:

      TypeDB.query(conn, "social", query, transaction_type: :read, answer_count_limit: 100)

  `TypeDB.Options.Query` and `TypeDB.Options.Transaction` are the canonical list
  of which key belongs to which set — the driver splits your keyword list by
  exactly that. `query_payload/2` and `transaction_payload/2` accept either form
  and are here for tooling that builds requests itself.

  ## Transaction options

    * `:transaction_timeout_millis` — how long the server keeps an idle
      transaction alive before killing it. This is a server-side setting and is
      passed straight through; how long the driver itself waits for a response
      is `:timeout`, on the connection or on the individual call.
    * `:schema_lock_acquire_timeout_millis` — how long a `schema` transaction
      waits for the exclusive schema lock.

  ## Query options

    * `:include_instance_types` — attach the type to every returned instance.
      **Turning it off is the largest saving available to a read**, and it is
      per query: only you know whether you already know the shape. Measured
      over an answer of 10,000 rows binding an entity and two attributes, on
      TypeDB 3.12.1:

      | | `true` (the default) | `false` |
      | --- | ---: | ---: |
      | bytes on the wire | 4,504,516 | 2,684,516 (−40%) |
      | decoding, end to end | 212 ms | 95 ms (2.2× faster) |
      | the decoded answer in memory | 8.16 MiB | 5.71 MiB (−30%) |

      The types are 40% of the bytes and half the decode. Leave it on while you
      are exploring, and turn it off on the read paths whose shape your code
      already knows.
    * `:answer_count_limit` — how many answers TypeDB materialises. **This
      raises TypeDB's own default of 10,000 as well as lowering it**: a read
      that matches more than that is truncated whether or not you set this, and
      the option is the only control — there is no server flag. Exceeding the
      limit produces a `warning` on the answer rather than an error, which the
      driver logs; see `TypeDB.Answer.warning/1`.
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

  # TypeDB's field names are lowerCamelCase and this driver's option names are
  # snake_case, so every set option had its name rebuilt — split, capitalise,
  # join — on every request. The set of names is five literals in this file, so
  # the work belongs to compilation rather than to the request: measured at
  # 1.83us per `query_payload/2` with one option set, against 0.081us reading
  # this table.
  #
  # Built from the two lists above rather than written out, so a key added to
  # either one cannot arrive on the wire without a name.
  @wire_names (for key <- @transaction_keys ++ @query_keys, into: %{} do
                 [first | rest] = key |> Atom.to_string() |> String.split("_")
                 {key, Enum.join([first | Enum.map(rest, &String.capitalize/1)])}
               end)

  @doc """
  Extracts transaction options, returning the wire payload or `nil` when none
  were given.

  `defaults` fills in options the caller did not set.
  """
  @spec transaction_payload(keyword() | Transaction.t() | nil, keyword()) :: map() | nil
  def transaction_payload(options, defaults \\ [])
  def transaction_payload(options, defaults), do: payload(options, defaults, @transaction_keys)

  @doc """
  Extracts query options, returning the wire payload or `nil` when none were
  given.

  `defaults` fills in options the caller did not set — used for the
  connection-level `:answer_count_limit`.
  """
  @spec query_payload(keyword() | Query.t() | nil, keyword()) :: map() | nil
  def query_payload(options, defaults \\ [])
  def query_payload(options, defaults), do: payload(options, defaults, @query_keys)

  # One path for both, and one conversion: a struct becomes a keyword list with
  # its unset fields dropped, exactly as if the caller had written that list.
  # The two used to differ — struct-to-map here, struct-to-keywords there — for
  # no reason other than having been written at different times.
  defp payload(nil, defaults, keys), do: payload([], defaults, keys)

  defp payload(%module{} = options, defaults, keys) when module in [Transaction, Query] do
    options
    |> Map.from_struct()
    |> Enum.reject(&match?({_key, nil}, &1))
    |> payload(defaults, keys)
  end

  defp payload(opts, defaults, keys) when is_list(opts) do
    defaults
    |> Keyword.take(keys)
    |> Keyword.merge(Keyword.take(opts, keys))
    |> Map.new()
    |> encode(keys)
  end

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
        {Map.fetch!(@wire_names, key), value}
      end

    if map_size(payload) == 0, do: nil, else: payload
  end
end
