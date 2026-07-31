exclude = if System.get_env("TYPEDB_INTEGRATION_URL"), do: [], else: [:integration]

ExUnit.start(exclude: exclude, capture_log: true)
