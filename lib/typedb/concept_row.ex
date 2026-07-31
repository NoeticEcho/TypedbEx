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

  alias TypeDB.Concept

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
  struct full of `nil`s. Convert the keys first:

      row
      |> TypeDB.ConceptRow.to_map()
      |> Map.new(fn {variable, value} -> {String.to_existing_atom(variable), value} end)
      |> then(&struct(Person, &1))

  `String.to_existing_atom/1` rather than `String.to_atom/1` so a query variable
  cannot grow the atom table; the struct's own fields already exist as atoms
  wherever `Person` is loaded. It raises `ArgumentError` for a variable that
  does not name one, which is the failure you want over a silent `nil`.
  """
  @spec to_map(t()) :: %{optional(String.t()) => term()}
  def to_map(%__MODULE__{data: data}) do
    Map.new(data, fn {variable, entry} -> {variable, unwrap(entry)} end)
  end

  defp unwrap(nil), do: nil
  defp unwrap(entries) when is_list(entries), do: Enum.map(entries, &unwrap/1)

  defp unwrap(concept) do
    case Concept.value(concept) do
      nil -> concept
      value -> value
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
