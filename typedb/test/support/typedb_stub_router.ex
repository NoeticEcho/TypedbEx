defmodule TypeDB.Stub.Router do
  @moduledoc """
  In-memory emulation of the TypeDB HTTP API v1, used by `TypeDB.Stub`.

  It reproduces the parts of the protocol the driver depends on — token issuing
  and expiry, database CRUD, transaction lifecycle, the one-shot query endpoint,
  and TypeDB's error body shape — over canned query answers. Semantics that
  differ from the obvious guess (creating an existing database succeeds, deleting
  a missing one does not) were verified against a live TypeDB 3.12.1 server.

  It does not implement TypeQL. Queries are answered from the `:answers` map
  passed to `TypeDB.Stub.start_link/1`, keyed by the exact query string, and
  otherwise fall back to a generic answer chosen by the query's leading keyword.
  """

  alias TypeDB.JSON

  @doc """
  Builds a handler function for `TypeDB.Stub`.
  """
  @spec build(keyword()) :: TypeDB.Stub.handler()
  def build(opts) do
    state = :ets.new(:typedb_stub_state, [:public, :set])

    :ets.insert(state, [
      {:username, Keyword.get(opts, :username, "admin")},
      {:password, Keyword.get(opts, :password, "password")},
      {:token_uses, Keyword.get(opts, :token_uses, :infinity)},
      {:token_ttl_ms, Keyword.get(opts, :token_ttl_ms, :infinity)},
      {:token_lifetime_seconds, Keyword.get(opts, :token_lifetime_seconds)},
      {:databases, MapSet.new(Keyword.get(opts, :databases, []))},
      {:users, MapSet.new(Keyword.get(opts, :users, ["admin"]))},
      {:transactions, %{}},
      {:answers, Keyword.get(opts, :answers, %{})},
      {:fail_commit, Keyword.get(opts, :fail_commit, false)},
      {:token_counter, 0}
    ])

    fn method, path, headers, body -> route(state, method, path, headers, body) end
  end

  defp route(state, method, path, headers, body) do
    segments = path |> String.split("?", parts: 2) |> hd() |> String.split("/", trim: true)

    case {method, segments} do
      {"GET", ["health"]} -> {204, [], ""}
      {"GET", ["v1", "health"]} -> {204, [], ""}
      {"GET", ["v1", "version"]} -> json(200, %{distribution: "TypeDB CE", version: "3.12.1"})
      {"POST", ["v1", "signin"]} -> signin(state, body)
      _ -> authenticated(state, method, segments, headers, body)
    end
  end

  defp authenticated(state, method, segments, headers, body) do
    case verify_token(state, headers) do
      :ok -> dispatch(state, method, segments, body)
      {:error, response} -> response
    end
  end

  defp dispatch(_state, "GET", ["v1", "servers"], _body) do
    json(200, %{servers: [%{address: "127.0.0.1:1729"}]})
  end

  defp dispatch(state, "GET", ["v1", "databases"], _body) do
    names = state |> get(:databases) |> Enum.sort() |> Enum.map(&%{name: &1})
    json(200, %{databases: names})
  end

  defp dispatch(state, "GET", ["v1", "databases", name], _body) do
    if MapSet.member?(get(state, :databases), name) do
      json(200, %{name: name})
    else
      error(404, "HSR4", "Requested resource not found.")
    end
  end

  # Verified against TypeDB 3.12.1: creating an existing database is a no-op that
  # answers 200 and leaves the data untouched.
  defp dispatch(state, "POST", ["v1", "databases", name], _body) do
    put(state, :databases, MapSet.put(get(state, :databases), name))
    {200, [], ""}
  end

  # ...while deleting a missing database is a 400, not a 404.
  defp dispatch(state, "DELETE", ["v1", "databases", name], _body) do
    databases = get(state, :databases)

    if MapSet.member?(databases, name) do
      put(state, :databases, MapSet.delete(databases, name))
      {200, [], ""}
    else
      error(400, "DBD1", "Cannot delete database since it does not exist.")
    end
  end

  defp dispatch(state, "GET", ["v1", "databases", name, "schema"], _body) do
    if MapSet.member?(get(state, :databases), name) do
      {200, [{"content-type", "text/plain"}], "define\n  entity person, owns name;\n"}
    else
      error(404, "SRV3", "Database '#{name}' not found.")
    end
  end

  defp dispatch(state, "GET", ["v1", "databases", name, "type-schema"], _body) do
    if MapSet.member?(get(state, :databases), name) do
      {200, [{"content-type", "text/plain"}], "define\n  entity person;\n"}
    else
      error(404, "SRV3", "Database '#{name}' not found.")
    end
  end

  defp dispatch(state, "GET", ["v1", "users"], _body) do
    users = state |> get(:users) |> Enum.sort() |> Enum.map(&%{username: &1})
    json(200, %{users: users})
  end

  # Every status and code below was read off a live TypeDB 3.12.1, because each
  # one of them is a different code and none of them is guessable. Unlike
  # database creation, which is idempotent, creating a user that exists is an
  # error — and each verb reports "no such user" under its own code.
  #
  #   GET    /v1/users/nobody      404 SRV4  "User not found."
  #   POST   /v1/users/existing    400 USC2  "User already exists."
  #   PUT    /v1/users/nobody      404 USU4  "User not found."
  #   DELETE /v1/users/nobody      404 USD3  "User not found."
  #   DELETE /v1/users/admin       400 USD1  "Default user cannot be deleted."
  #
  # And, on the transaction and database endpoints:
  #
  #   GET  /v1/databases/nope/schema     404 SRV3  "Database 'nope' not found."
  #   POST /v1/transactions/open (nope)  400 SRV3  — a 400, unlike the GET above
  #   POST /v1/query (nope)              400 SRV3
  #   POST /v1/transactions/{gone}/*     404 TSV12 "Operation failed: no open transaction."
  #   POST /v1/transactions/{read}/commit    400 TSV2  "Read transactions cannot be committed."
  #   POST /v1/transactions/{read}/rollback  400 TSV3  "Read transactions cannot be rolled back..."
  #
  # Five of those the stub had invented, and every one of them was asserted by a
  # test. See test/integration/error_code_integration_test.exs, which pins them
  # against a live server so this comment stops being the only guard.
  defp dispatch(state, "GET", ["v1", "users", username], _body) do
    if MapSet.member?(get(state, :users), username) do
      json(200, %{username: username})
    else
      error(404, "SRV4", "User not found.")
    end
  end

  defp dispatch(state, "POST", ["v1", "users", username], _body) do
    if MapSet.member?(get(state, :users), username) do
      error(400, "USC2", "User already exists.")
    else
      put(state, :users, MapSet.put(get(state, :users), username))
      {200, [], ""}
    end
  end

  defp dispatch(state, "PUT", ["v1", "users", username], _body) do
    if MapSet.member?(get(state, :users), username) do
      {200, [], ""}
    else
      error(404, "USU4", "User not found.")
    end
  end

  defp dispatch(state, "DELETE", ["v1", "users", username], _body) do
    if MapSet.member?(get(state, :users), username) do
      put(state, :users, MapSet.delete(get(state, :users), username))
      {200, [], ""}
    else
      error(404, "USD3", "User not found.")
    end
  end

  defp dispatch(state, "POST", ["v1", "transactions", "open"], body) do
    payload = decode(body)
    database = payload["databaseName"]

    if MapSet.member?(get(state, :databases), database) do
      id = "tx-#{System.unique_integer([:positive, :monotonic])}"

      put(
        state,
        :transactions,
        Map.put(get(state, :transactions), id, %{
          database: database,
          type: payload["transactionType"],
          state: :open
        })
      )

      json(200, %{transactionId: id})
    else
      error(400, "SRV3", "Database '#{database}' not found.")
    end
  end

  defp dispatch(state, "POST", ["v1", "transactions", id, action], body) do
    transactions = get(state, :transactions)

    case {Map.fetch(transactions, id), action} do
      {{:ok, transaction}, _} ->
        transaction_action(state, id, transaction, action, body)

      # Verified against TypeDB 3.12.1: closing an unknown transaction succeeds,
      # while every other action on one is a 404.
      {:error, "close"} ->
        {200, [], ""}

      {:error, _} ->
        error(404, "TSV12", "Operation failed: no open transaction.")
    end
  end

  defp dispatch(state, "POST", ["v1", "query"], body) do
    payload = decode(body)

    if MapSet.member?(get(state, :databases), payload["databaseName"]) do
      json(200, answer_for(state, payload["query"]))
    else
      error(400, "SRV3", "Database '#{payload["databaseName"]}' not found.")
    end
  end

  defp dispatch(_state, _method, _segments, _body) do
    error(404, "HSR4", "Requested resource not found.")
  end

  defp transaction_action(state, id, transaction, action, body) do
    case action do
      "query" ->
        payload = decode(body)
        json(200, answer_for(state, payload["query"]))

      "analyze" ->
        json(200, %{query: %{stages: []}})

      "commit" when transaction.type == "read" ->
        error(400, "TSV2", "Read transactions cannot be committed.")

      "commit" ->
        if get(state, :fail_commit) do
          error(400, "TSV6", "Data commit failed.")
        else
          put(state, :transactions, Map.delete(get(state, :transactions), id))
          {200, [], ""}
        end

      action when action in ["commit", "rollback", "close"] ->
        if action != "rollback" do
          put(state, :transactions, Map.delete(get(state, :transactions), id))
        end

        {200, [], ""}

      _ ->
        error(404, "HSR4", "Requested resource not found.")
    end
  end

  # ----------------------------------------------------------------------------
  # Authentication
  # ----------------------------------------------------------------------------

  defp signin(state, body) do
    payload = decode(body)

    if payload["username"] == get(state, :username) and payload["password"] == get(state, :password) do
      # Counter and token row are updated atomically: sign-in is concurrent, and
      # a lost update here would surface as a spurious "unknown token".
      counter = :ets.update_counter(state, :token_counter, 1)
      token = mint_token(state, counter)
      :ets.insert(state, {{:token, token}, 0, System.monotonic_time(:millisecond)})
      json(200, %{token: token})
    else
      error(401, "AUT1", "Invalid credential supplied.")
    end
  end

  # Real TypeDB hands out JWTs carrying `iat`/`exp`, which is what lets the driver
  # renew before a token expires. `:token_lifetime_seconds` controls the claim;
  # `:token_ttl_ms` controls when the stub actually starts rejecting it, so a test
  # can make the two disagree on purpose.
  defp mint_token(state, counter) do
    claims =
      case get(state, :token_lifetime_seconds) do
        nil -> nil
        seconds -> %{"sub" => get(state, :username), "iat" => 0, "exp" => seconds}
      end

    case claims do
      nil ->
        "stub-token-#{counter}"

      claims ->
        segment = fn term -> term |> JSON.encode!() |> Base.url_encode64(padding: false) end

        segment.(%{"typ" => "JWT", "alg" => "HS256"}) <>
          "." <> segment.(Map.put(claims, "jti", counter)) <> ".stub-signature"
    end
  end

  defp verify_token(state, headers) do
    case Map.fetch(headers, "authorization") do
      {:ok, "Bearer " <> token} -> verify_bearer(state, token)
      _ -> {:error, error(401, "AUT2", "Missing token (expected as the authorization bearer).")}
    end
  end

  # Two independent expiry models, because they test different things:
  #
  #   * `:token_ttl_ms` mirrors a real server — a token is shared by everyone
  #     holding it and dies at a wall-clock deadline
  #   * `:token_uses` is a blunt instrument for forcing an exact number of 401s
  #     in a sequential test
  defp verify_bearer(state, token) do
    case :ets.lookup(state, {:token, token}) do
      [{_key, _uses, issued_at}] -> check_expiry(state, token, issued_at)
      [] -> {:error, error(401, "AUT3", "Invalid token supplied.")}
    end
  end

  defp check_expiry(state, token, issued_at) do
    ttl = get(state, :token_ttl_ms)
    age = System.monotonic_time(:millisecond) - issued_at

    cond do
      # `>=` so that `token_ttl_ms: 0` means "already expired" deterministically,
      # rather than depending on whether the request beat the clock's next tick.
      ttl != :infinity and age >= ttl ->
        {:error, error(401, "AUT3", "Invalid token supplied.")}

      get(state, :token_uses) == :infinity ->
        :ok

      true ->
        # update_counter is atomic, so concurrent uses cannot lose a count.
        limit = get(state, :token_uses)

        if :ets.update_counter(state, {:token, token}, {2, 1}) <= limit do
          :ok
        else
          {:error, error(401, "AUT3", "Invalid token supplied.")}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Answers
  # ----------------------------------------------------------------------------

  defp answer_for(state, query) do
    answers = get(state, :answers)

    case Map.fetch(answers, query) do
      {:ok, answer} -> answer
      :error -> default_answer(query)
    end
  end

  defp default_answer(query) when is_binary(query) do
    cond do
      String.starts_with?(query, "define") or String.starts_with?(query, "undefine") ->
        %{queryType: "schema", answerType: "ok", answers: nil, query: nil, warning: nil}

      String.starts_with?(query, "insert") or String.starts_with?(query, "delete") or
          String.starts_with?(query, "update") ->
        %{
          queryType: "write",
          answerType: "conceptRows",
          answers: [%{data: %{}, involvedBlocks: nil}],
          query: nil,
          warning: nil
        }

      String.contains?(query, "fetch") ->
        %{queryType: "read", answerType: "conceptDocuments", answers: [%{"name" => "Alice"}], warning: nil}

      true ->
        %{
          queryType: "read",
          answerType: "conceptRows",
          answers: [
            %{
              data: %{
                "p" => %{
                  kind: "entity",
                  iid: "0x1e00000000000000000000",
                  type: %{kind: "entityType", label: "person"}
                },
                "name" => %{
                  kind: "attribute",
                  iid: "0x1e00000000000000000001",
                  value: "Alice",
                  valueType: "string",
                  type: %{kind: "attributeType", label: "name", valueType: "string"}
                }
              },
              involvedBlocks: nil
            }
          ],
          query: nil,
          warning: nil
        }
    end
  end

  defp default_answer(_query), do: %{queryType: "read", answerType: "ok", answers: nil}

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp get(state, key) do
    [{^key, value}] = :ets.lookup(state, key)
    value
  end

  defp put(state, key, value), do: :ets.insert(state, {key, value})

  defp decode(""), do: %{}

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp json(status, payload), do: {status, [{"content-type", "application/json"}], JSON.encode!(payload)}

  defp error(status, code, message) do
    json(status, %{code: code, message: message})
  end
end
