defmodule TypeDB.Answer do
  @moduledoc """
  The result of a TypeQL query.

  TypeDB answers come in three shapes, and the driver gives each its own struct so
  you can pattern match on the one you expect:

    * `TypeDB.Answer.Ok` — the query produced no answers. `define`, `undefine`,
      and writes whose results were not requested.
    * `TypeDB.Answer.ConceptRows` — a `match`/`insert`/`update` pipeline. Each row
      binds query variables to concepts.
    * `TypeDB.Answer.ConceptDocuments` — a `fetch` pipeline. Each document is
      plain decoded JSON, shaped by the query itself.

  Every answer carries `query_type` (`:read`, `:write` or `:schema`), which is
  what TypeDB determined the query to be — not what you asked for.

      case TypeDB.query!(conn, "social", "match $p isa person; select $p;") do
        %TypeDB.Answer.ConceptRows{rows: rows} -> length(rows)
        %TypeDB.Answer.Ok{} -> 0
      end

  `ConceptRows` and `ConceptDocuments` are `Enumerable`, so they can be piped
  straight into `Enum` and `Stream`:

      conn
      |> TypeDB.query!("social", "match $p isa person; select $p;")
      |> Enum.map(&TypeDB.ConceptRow.typed_value(&1, "p"))
  """

  alias TypeDB.{ConceptRow, Error}

  @typedoc "What TypeDB classified the query as."
  @type query_type :: :read | :write | :schema

  defmodule Ok do
    @moduledoc "An answer with no results, e.g. from `define` or `undefine`."
    @type t :: %__MODULE__{query_type: TypeDB.Answer.query_type(), warning: String.t() | nil}
    @enforce_keys [:query_type]
    defstruct [:query_type, :warning]
  end

  defmodule ConceptRows do
    @moduledoc """
    Rows of variable bindings. Implements `Enumerable` over `rows`.
    """
    @type t :: %__MODULE__{
            query_type: TypeDB.Answer.query_type(),
            rows: [TypeDB.ConceptRow.t()],
            warning: String.t() | nil,
            query_structure: map() | nil
          }
    @enforce_keys [:query_type, :rows]
    defstruct [:query_type, :rows, :warning, :query_structure]

    defimpl Enumerable do
      def count(%{rows: rows}), do: {:ok, length(rows)}
      def member?(%{rows: rows}, element), do: {:ok, Enum.member?(rows, element)}
      def slice(%{rows: rows}), do: Enumerable.List.slice(rows)
      def reduce(%{rows: rows}, acc, fun), do: Enumerable.List.reduce(rows, acc, fun)
    end
  end

  defmodule ConceptDocuments do
    @moduledoc """
    JSON documents produced by a `fetch` pipeline. Implements `Enumerable` over
    `documents`.
    """
    @type t :: %__MODULE__{
            query_type: TypeDB.Answer.query_type(),
            documents: [term()],
            warning: String.t() | nil
          }
    @enforce_keys [:query_type, :documents]
    defstruct [:query_type, :documents, :warning]

    defimpl Enumerable do
      def count(%{documents: documents}), do: {:ok, length(documents)}
      def member?(%{documents: documents}, element), do: {:ok, Enum.member?(documents, element)}
      def slice(%{documents: documents}), do: Enumerable.List.slice(documents)
      def reduce(%{documents: documents}, acc, fun), do: Enumerable.List.reduce(documents, acc, fun)
    end
  end

  @type t :: Ok.t() | ConceptRows.t() | ConceptDocuments.t()

  @doc false
  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(%{"answerType" => answer_type, "queryType" => query_type} = payload) do
    with {:ok, query_type} <- decode_query_type(query_type) do
      warning = Map.get(payload, "warning")

      case answer_type do
        "ok" ->
          {:ok, %Ok{query_type: query_type, warning: warning}}

        "conceptRows" ->
          {:ok,
           %ConceptRows{
             query_type: query_type,
             rows: payload |> answers() |> Enum.map(&ConceptRow.decode/1),
             warning: warning,
             query_structure: Map.get(payload, "query")
           }}

        "conceptDocuments" ->
          {:ok, %ConceptDocuments{query_type: query_type, documents: answers(payload), warning: warning}}

        other ->
          {:error, Error.new(:decode, "unknown TypeDB answer type #{inspect(other)}", body: payload)}
      end
    end
  rescue
    error in Error -> {:error, error}
  end

  def decode(payload) do
    {:error, Error.new(:decode, "malformed TypeDB query answer", body: payload)}
  end

  defp answers(payload) do
    case Map.get(payload, "answers") do
      nil ->
        []

      answers when is_list(answers) ->
        answers

      other ->
        raise Error.new(:decode, "TypeDB answer payload had a non-list \"answers\" field", body: other)
    end
  end

  defp decode_query_type("read"), do: {:ok, :read}
  defp decode_query_type("write"), do: {:ok, :write}
  defp decode_query_type("schema"), do: {:ok, :schema}

  defp decode_query_type(other) do
    {:error, Error.new(:decode, "unknown TypeDB query type #{inspect(other)}")}
  end

  @doc """
  Returns the rows of a `ConceptRows` answer, or `[]` for any other answer.
  """
  @spec rows(t()) :: [ConceptRow.t()]
  def rows(%ConceptRows{rows: rows}), do: rows
  def rows(_answer), do: []

  @doc """
  Returns the documents of a `ConceptDocuments` answer, or `[]` for any other.
  """
  @spec documents(t()) :: [term()]
  def documents(%ConceptDocuments{documents: documents}), do: documents
  def documents(_answer), do: []

  @doc """
  Returns the server-side warning attached to an answer, if any.

  TypeDB uses warnings for things like an answer set truncated by
  `answer_count_limit`.
  """
  @spec warning(t()) :: String.t() | nil
  def warning(%Ok{warning: warning}), do: warning
  def warning(%ConceptRows{warning: warning}), do: warning
  def warning(%ConceptDocuments{warning: warning}), do: warning

  @doc """
  Returns the query type TypeDB classified this query as.
  """
  @spec query_type(t()) :: query_type()
  def query_type(%Ok{query_type: type}), do: type
  def query_type(%ConceptRows{query_type: type}), do: type
  def query_type(%ConceptDocuments{query_type: type}), do: type
end
