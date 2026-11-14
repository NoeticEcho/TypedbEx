defmodule TypeDB.Vector do
  @moduledoc """
  Vector values — **experimental**. They need a TypeDB build with vector
  support, which no release is yet, started with
  `--experimental-vector-search-enabled=true`; the syntax and the wire format
  may change until TypeDB releases them.

  A vector attribute is declared with its dimension and dtype (`float32` is the
  only one), and searched by cosine similarity through an HNSW index the
  attribute declares:

      define
        attribute embedding, value vector(1024, "float32") @index(hnsw:cosine);
        entity memory, owns embedding;

      given $q: vector(1024, "float32");
      match let $e, $score in cosine_similarity_search(embedding, $q, 0.55);
        $m isa memory, has embedding $e;
      select $m, $score; sort $score desc; limit 10;

  `$score` is a `double`, and the search returns every match above the
  threshold, so `sort` and `limit` are what make it a top-k. A query with
  several `given` rows runs once per row and sorts and limits across all of
  them.

  `value/1` builds the term to pass in `given_rows`, and the same term works
  over `typedb_grpc`:

      TypeDB.query(conn, "memories", query,
        transaction_type: :read,
        given_rows: [%{"q" => TypeDB.Vector.value!(embedding)}]
      )

  ## What the driver checks, and what the server does

  Before a request is sent, a vector's length must match the dimension its
  `value_type` declares, and every component must be a number a `float32`
  holds. Anything else is `TypeDB.Error` with kind `:encode`, raised from
  `TypeDB.Given` as for any value it cannot encode, so nothing reaches the
  server. A number past `float32`'s range would otherwise become an infinity
  on the server.

  Observed on the build `3.14.1-dev`, commit `11ab292c` (2026-11-12): the
  server refuses a stored vector with a non-finite component (`DVL23`) and a
  query vector of zero norm (`COR32`); a stored zero vector matches nothing;
  `sort` on a vector-valued variable is refused (`QUA20`). **A similarity
  search inside `not { }` or inside a branch of `or { }` panics the server
  process**, taking every database down; keep the search in the query's top
  conjunction. A negation over a relation beside a search is fine.
  """

  alias TypeDB.Concept.Value

  @float32_max (fn ->
                  <<max::float-32>> = <<0x7F7F_FFFF::32>>
                  max
                end).()

  @doc """
  The `given` term for a vector of these components, as `vector(N, "float32")`.

      iex> TypeDB.Vector.value([1, 0.5])
      {:ok, %TypeDB.Concept.Value{value: [1.0, 0.5], value_type: ~s|vector(2, "float32")|}}

      iex> TypeDB.Vector.value([1.0e39])
      {:error, %TypeDB.Error{kind: :encode, message: "cannot encode [1.0e39] as a vector: expected a non-empty list of numbers, each a finite float32"}}
  """
  @spec value([number()]) :: {:ok, Value.t()} | {:error, TypeDB.Error.t()}
  def value(components) do
    case floats(components) do
      {:ok, floats} ->
        {:ok, %Value{value: floats, value_type: ~s|vector(#{length(floats)}, "float32")|}}

      :error ->
        {:error, error(components, "a vector")}
    end
  end

  @doc "As `value/1`, raising the error."
  @spec value!([number()]) :: Value.t()
  def value!(components) do
    case value(components) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc false
  # The components of a vector value of `value_type`, as floats, or a raised
  # `:encode` error. `TypeDB.Given` calls it for every vector it encodes.
  def check!(components, value_type) do
    with {:ok, dimension} <- dimension(value_type),
         {:ok, floats} <- floats(components),
         true <- length(floats) == dimension do
      floats
    else
      {:error, :value_type} ->
        raise TypeDB.Error.new(
                :encode,
                ~s|unsupported vector type #{inspect(value_type)}, expected vector(N, "float32")|
              )

      _ ->
        raise error(components, value_type)
    end
  end

  defp dimension(value_type) do
    case Regex.run(~r/\Avector\((\d+),\s*"float32"\)\z/, value_type) do
      [_, dimension] -> {:ok, String.to_integer(dimension)}
      nil -> {:error, :value_type}
    end
  end

  defp floats([_ | _] = components) do
    floats = Enum.map(components, &float32/1)
    if :error in floats, do: :error, else: {:ok, floats}
  end

  defp floats(_), do: :error

  defp float32(x) when is_integer(x) and abs(x) <= @float32_max, do: x * 1.0
  defp float32(x) when is_float(x) and abs(x) <= @float32_max, do: x
  defp float32(_x), do: :error

  defp error(components, what) do
    expected =
      if what == "a vector",
        do: "a non-empty list of numbers",
        else: "as many numbers as it declares"

    TypeDB.Error.new(
      :encode,
      "cannot encode #{inspect(components, limit: 5)} as #{what}: " <>
        "expected #{expected}, each a finite float32"
    )
  end
end
