# Integration tests need a running TypeDB server; TLS tests additionally need one
# with encryption enabled. `:slow` tests spend real seconds waiting for timeouts
# to expire. All three are opt-in through the environment so that `mix test`
# alone is always runnable, hermetic and quick.
exclude =
  []
  |> then(&if System.get_env("TYPEDB_INTEGRATION_URL"), do: &1, else: [:integration | &1])
  |> then(&if System.get_env("TYPEDB_TLS_URL"), do: &1, else: [:tls | &1])
  |> then(&if System.get_env("TYPEDB_SLOW_TESTS"), do: &1, else: [:slow | &1])

ExUnit.start(exclude: Enum.uniq(exclude), capture_log: true)
