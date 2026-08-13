defmodule TypeDB.Bang do
  @moduledoc false

  # Macros, not functions: a `!` helper shared as a function has one success
  # typing, which widens to the union of every caller's return type, and dialyzer
  # then reports each `!` function as under-specified. Inlined at the call site,
  # each one keeps its own types.
  #
  # Two of them because `:ok` and `{:ok, value}` are different shapes and the
  # compiler rightly objects to a clause that can never match.

  defmacro __using__(_opts) do
    quote do
      import TypeDB.Bang, only: [unwrap!: 1, ok!: 1]
    end
  end

  defmacro unwrap!(call) do
    quote do
      case unquote(call) do
        {:ok, value} -> value
        {:error, error} -> raise error
      end
    end
  end

  defmacro ok!(call) do
    quote do
      case unquote(call) do
        :ok -> :ok
        {:error, error} -> raise error
      end
    end
  end
end
