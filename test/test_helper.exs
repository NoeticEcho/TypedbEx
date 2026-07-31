# Integration tests need a running TypeDB server; TLS tests additionally need one
# with encryption enabled. Both are opt-in through the environment so that
# `mix test` alone is always runnable and hermetic.
exclude =
  []
  |> then(&if System.get_env("TYPEDB_INTEGRATION_URL"), do: &1, else: [:integration | &1])
  |> then(&if System.get_env("TYPEDB_TLS_URL"), do: &1, else: [:tls | &1])

ExUnit.start(exclude: Enum.uniq(exclude), capture_log: true)
