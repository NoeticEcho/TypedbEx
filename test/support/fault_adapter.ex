defmodule TypeDB.FaultAdapter do
  @moduledoc """
  An HTTP adapter that fails on purpose, one way per fault.

  `TypeDB.Transport.contain/3` promises that nothing an adapter does escapes as
  a bare exception: `TypeDB.HTTP` is a public extension point, anyone may
  implement it, and even the shipped adapters raise — Finch raises rather than
  returns when its pool is exhausted. That promise was tested with a handful of
  hand-written adapters, one per test.

  This is the whole matrix instead: every fault an adapter can produce, and
  every fault a *server* can produce that the adapter will pass through happily.

  Pair it with `token: "t"` so no sign-in is attempted — the fault would
  otherwise be met first by the connection's own start-up, which is a different
  path with its own tests.
  """

  @behaviour TypeDB.HTTP

  @faults [
    # The adapter itself misbehaving.
    :raise,
    :throw,
    :exit,
    :nonsense_return,
    :missing_keys,
    # A response that arrived but is not what it claims to be.
    :truncated_body,
    :malformed_json,
    :wrong_content_type,
    :empty_body,
    :huge_body,
    # A response that is honestly a failure.
    :server_error,
    :html_error_page,
    :timeout_error
  ]

  @doc "Every fault this adapter knows how to produce."
  @spec faults() :: [atom()]
  def faults, do: @faults

  @impl true
  def init(_name, opts), do: {:ok, Keyword.fetch!(opts, :fault)}

  @impl true
  def request(fault, _method, _url, _headers, _body, _opts), do: respond(fault)

  defp respond(:raise), do: raise("the adapter blew up")
  defp respond(:throw), do: throw(:the_adapter_threw)
  defp respond(:exit), do: exit(:the_adapter_exited)
  defp respond(:nonsense_return), do: :surprise
  defp respond(:missing_keys), do: {:ok, %{status: 200}}

  defp respond(:truncated_body), do: json(200, ~s({"answerType":"conceptRows","quer))
  defp respond(:malformed_json), do: json(200, "{not json at all}")
  defp respond(:empty_body), do: json(200, "")
  defp respond(:huge_body), do: json(200, String.duplicate("x", 500_000))

  defp respond(:wrong_content_type) do
    {:ok, %{status: 200, headers: [{"content-type", "text/html"}], body: "<html>hello</html>"}}
  end

  defp respond(:server_error), do: json(503, ~s({"code":"SRV9","message":"unavailable"}))

  defp respond(:html_error_page) do
    {:ok,
     %{
       status: 502,
       headers: [{"content-type", "text/html"}],
       body: "<html><body><h1>502 Bad Gateway</h1></body></html>"
     }}
  end

  defp respond(:timeout_error), do: {:error, TypeDB.Error.new(:timeout, "took too long")}

  defp json(status, body) do
    {:ok, %{status: status, headers: [{"content-type", "application/json"}], body: body}}
  end
end
