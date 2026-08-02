defmodule TypeDB.ConceptRow do
  @moduledoc """
  One row of a `conceptRows` answer: a map from variable name to concept.

  Rows implement `Access`, so a variable can be read directly:

      row["person"]
      #=> %TypeDB.Concept.Entity{iid: "0x1e0...", type: %TypeDB.Concept.EntityType{label: "person"}}

      get_in(row, ["name"])
      #=> %TypeDB.Concept.Attribute{value: "Alice", value_type: "string"}

  A variable bound to nothing yields `nil`, which is indistinguishable from an
  absent variable through `Access`. Use `fetch/2` when the difference matters.

  `involved_blocks` is populated only when the query ran with
  `include_query_structure: true`; it lists the ids of the query blocks that
  produced this row.
  """

  alias TypeDB.{CallOptions, Concept}

  @type t :: %__MODULE__{
          data: %{optional(String.t()) => Concept.entry()},
          involved_blocks: [non_neg_integer()] | nil
        }

  @enforce_keys [:data]
  defstruct data: %{}, involved_blocks: nil

  @behaviour Access

  @doc false
  @spec decode(term()) :: t()
  def decode(%{"data" => data} = row) when is_map(data) do
    %__MODULE__{
      data: Map.new(data, fn {variable, entry} -> {variable, Concept.decode(entry)} end),
      involved_blocks: Map.get(row, "involvedBlocks")
    }
  end

  def decode(other) do
    raise TypeDB.Error.new(:decode, "unrecognised TypeDB concept row: #{inspect(other)}", body: other)
  end

  @doc """
  Returns the variable names bound in this row.
  """
  @spec variables(t()) :: [String.t()]
  def variables(%__MODULE__{data: data}), do: Map.keys(data)

  @doc """
  Fetches a variable, distinguishing "bound to nothing" from "not present".

      {:ok, nil}   # the variable exists but matched nothing
      :error       # the variable is not in this row
  """
  @spec fetch(t(), String.t()) :: {:ok, Concept.entry()} | :error
  @impl Access
  def fetch(%__MODULE__{data: data}, variable), do: Map.fetch(data, variable)

  @doc """
  Returns a variable's concept, or `default` when it is absent or unbound.
  """
  @spec get(t(), String.t(), term()) :: Concept.entry() | term()
  def get(%__MODULE__{data: data}, variable, default \\ nil) do
    case Map.fetch(data, variable) do
      {:ok, nil} -> default
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Returns the wire value of a variable bound to an attribute or value.
  """
  @spec value(t(), String.t()) :: term()
  def value(%__MODULE__{} = row, variable) do
    case get(row, variable) do
      nil -> nil
      concept -> Concept.value(concept)
    end
  end

  @doc """
  Returns the natively typed value of a variable. See `TypeDB.Concept.typed_value/1`.
  """
  @spec typed_value(t(), String.t()) :: term()
  def typed_value(%__MODULE__{} = row, variable) do
    case get(row, variable) do
      nil -> nil
      concept -> Concept.typed_value(concept)
    end
  end

  @doc """
  Returns the row as a plain map of variable name to wire value.

  The keys are **strings** — the query's own variable names, exactly as TypeDB
  sent them back.

  That matters if you are reaching for `Kernel.struct/2`, which ignores keys
  that are not atoms naming a field: handed a string-keyed map it returns the
  struct's defaults and reports nothing, so the conversion silently produces a
  struct full of `nil`s. Use `to_struct/3` instead.

  The values are TypeDB's own, exactly as they arrived — a `decimal` is the
  string `"12.345dec"`, TypeQL's literal suffix and all, and a `duration` the
  string `"P1Y2M3DT4H5M6S"`. `to_typed_map/1` is the same map with every value
  cast to a native Elixir term.
  """
  @spec to_map(t()) :: %{optional(String.t()) => term()}
  def to_map(%__MODULE__{data: data}) do
    Map.new(data, fn {variable, entry} -> {variable, unwrap(entry, &Concept.value/1)} end)
  end

  @doc """
  Returns the row as a plain map of variable name to *native* Elixir term.

  `to_map/1` with `typed_value/2`'s conversions applied to every value, so a
  whole row can be read natively in one call rather than a variable at a time:
  a `datetime` arrives as a `NaiveDateTime`, a `duration` as a
  `TypeDB.Duration`, a `decimal` as a `Decimal` when that optional dependency is
  loaded. See `TypeDB.Concept.typed_value/1` for the full table.

  Concepts that are not attributes or values — an entity, a relation, a type —
  are left alone, exactly as `to_map/1` leaves them.

      TypeDB.ConceptRow.to_map(row)
      #=> %{"name" => "Alice", "worked" => "P1Y2M3DT4H5M6S"}

      TypeDB.ConceptRow.to_typed_map(row)
      #=> %{"name" => "Alice", "worked" => %TypeDB.Duration{months: 14, days: 3, nanos: 14706000000000, raw: "P1Y2M3DT4H5M6S"}}
  """
  @spec to_typed_map(t()) :: %{optional(String.t()) => term()}
  def to_typed_map(%__MODULE__{data: data}) do
    Map.new(data, fn {variable, entry} -> {variable, unwrap(entry, &Concept.typed_value/1)} end)
  end

  @doc """
  Builds a struct out of the row, matching variable names to field names.

  `Kernel.struct/2` cannot do this: handed a string-keyed map it ignores every
  key and hands back the struct's defaults, so a mistyped variable produces a
  struct full of `nil`s and no complaint. This raises instead, naming the
  variable and listing the fields that do exist.

      defmodule Person do
        defstruct [:name, :age]
      end

      TypeDB.query!(conn, "social", "match $p isa person, has name $name, has age $age;")
      |> Enum.map(&TypeDB.ConceptRow.to_struct(&1, Person))
      #=> [%Person{name: "Alice", age: 31}]

  Values are unwrapped as `to_map/1` unwraps them — TypeDB's own, uncast. Pass
  `typed: true` for `to_typed_map/1`'s conversions instead, which is what you
  want if a field holds a duration, a decimal or a timestamp:

      TypeDB.ConceptRow.to_struct(row, Shift, typed: true)
      #=> %Shift{worked: %TypeDB.Duration{months: 14, days: 3, nanos: 14706000000000, raw: "P1Y2M3DT4H5M6S"}}

  A field the query did not select keeps the struct's own default, since
  selecting a subset of the fields is an ordinary thing to want; a *variable*
  with no matching field is a mistake, and is reported as one.

  ## Examples

      iex> row = %TypeDB.ConceptRow{data: %{"scheme" => nil, "host" => nil}}
      iex> TypeDB.ConceptRow.to_struct(row, URI)
      %URI{scheme: nil, host: nil}

      iex> row = %TypeDB.ConceptRow{data: %{"hsot" => nil}}
      iex> TypeDB.ConceptRow.to_struct(row, URI)
      ** (ArgumentError) query variable "hsot" does not name a field of URI. Its fields are: :authority, :fragment, :host, :path, :port, :query, :scheme, :userinfo
  """
  @spec to_struct(t(), module(), keyword()) :: struct()
  def to_struct(%__MODULE__{} = row, module, opts \\ []) when is_atom(module) do
    CallOptions.validate!(opts, [:typed], "TypeDB.ConceptRow.to_struct/3")
    fields = struct_fields(module)

    row
    |> then(if Keyword.get(opts, :typed, false), do: &to_typed_map/1, else: &to_map/1)
    |> Map.new(fn {variable, value} ->
      case Map.fetch(fields, variable) do
        {:ok, field} ->
          {field, value}

        :error ->
          raise ArgumentError,
                "query variable #{inspect(variable)} does not name a field of " <>
                  "#{inspect(module)}. Its fields are: " <>
                  Enum.map_join(Enum.sort(Map.values(fields)), ", ", &inspect/1)
      end
    end)
    |> then(&struct(module, &1))
  end

  # Keyed by string so that a variable name never has to become an atom: even
  # `String.to_existing_atom/1` would raise for a variable that happens to name
  # an atom somewhere else in the system, which is a confusing way to be told
  # that a struct has no such field.
  defp struct_fields(module) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
    |> Map.new(&{Atom.to_string(&1), &1})
  rescue
    UndefinedFunctionError ->
      reraise ArgumentError, [message: "#{inspect(module)} is not a struct"], __STACKTRACE__
  end

  defp unwrap(nil, _value), do: nil
  defp unwrap(entries, value) when is_list(entries), do: Enum.map(entries, &unwrap(&1, value))

  # A concept that is not an attribute or a value has no value to unwrap — an
  # entity, a relation, a type — and is handed back whole.
  defp unwrap(concept, value) do
    case value.(concept) do
      nil -> concept
      unwrapped -> unwrapped
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{data: data} = row, variable, fun) do
    {current, updated} = Access.get_and_update(data, variable, fun)
    {current, %{row | data: updated}}
  end

  @impl Access
  def pop(%__MODULE__{data: data} = row, variable) do
    {value, updated} = Access.pop(data, variable)
    {value, %{row | data: updated}}
  end
end
