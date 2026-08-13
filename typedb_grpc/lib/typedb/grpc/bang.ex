defmodule TypeDB.GRPC.Bang do
  @moduledoc false

  # A copy of `TypeDB.Bang`, deliberately, and the reasoning is worth recording
  # because this package borrows another private module — `TypeDB.Token` — rather
  # than copying it.
  #
  # The difference is compile time. `TypeDB.Token` is a function: if the sibling
  # changes it, a test in this package goes red and somebody follows the change.
  # These are *macros*, expanded into this package's code at compile time — so a
  # rename in the sibling would fail this package's *build*, on the machine of
  # whoever ran `mix deps.update typedb`, for a module its docs describe as
  # internal. Thirty lines of duplication is cheaper than that.
  #
  # Why macros at all, from the original: a `!` helper shared as a *function* has
  # one success typing, which widens to the union of every caller's return type,
  # and Dialyzer then reports each `!` function as under-specified. Inlined at
  # the call site, each keeps its own types.
  #
  # Two of them, because `:ok` and `{:ok, value}` are different shapes and the
  # compiler rightly objects to a clause that can never match.

  defmacro __using__(_opts) do
    quote do
      import TypeDB.GRPC.Bang, only: [unwrap!: 1, ok!: 1]
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
