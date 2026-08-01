defmodule TypeDB.ConfigTest do
  use ExUnit.Case, async: true

  alias TypeDB.{Config, Error}

  doctest TypeDB.Config

  describe "new/1 url parsing" do
    test "accepts a full url" do
      assert {:ok, config} = Config.new(url: "http://localhost:8000", token: "t")
      assert config.base_url == "http://localhost:8000"
    end

    test "defaults a bare host:port to http" do
      assert {:ok, config} = Config.new(url: "typedb.internal:8000", token: "t")
      assert config.base_url == "http://typedb.internal:8000"
    end

    test "defaults a bare host to http" do
      assert {:ok, config} = Config.new(url: "typedb.internal", token: "t")
      assert config.base_url == "http://typedb.internal"
    end

    test "keeps https and a non-default port" do
      assert {:ok, config} = Config.new(url: "https://typedb.internal:8443", token: "t")
      assert config.base_url == "https://typedb.internal:8443"
    end

    test "elides default ports" do
      assert {:ok, %{base_url: "https://typedb.internal"}} =
               Config.new(url: "https://typedb.internal:443", token: "t")

      assert {:ok, %{base_url: "http://typedb.internal"}} =
               Config.new(url: "http://typedb.internal:80", token: "t")
    end

    test "keeps a base path but drops its trailing slash" do
      assert {:ok, config} = Config.new(url: "https://gateway.internal/typedb/", token: "t")
      assert config.base_url == "https://gateway.internal/typedb"
      assert Config.url(config, "/databases") == "https://gateway.internal/typedb/v1/databases"
    end

    test "rejects a non-http scheme" do
      assert {:error, %Error{kind: :config, message: message}} = Config.new(url: "ftp://host", token: "t")
      assert message =~ "invalid :url"
    end

    test "rejects a non-string url" do
      assert {:error, %Error{kind: :config}} = Config.new(url: :localhost, token: "t")
    end

    test "keeps an IPv6 literal usable" do
      # URI strips the brackets; putting the host back without them yields
      # "http://::1:8000", which no HTTP client can connect to.
      assert {:ok, config} = Config.new(url: "http://[::1]:8000", token: "t")
      assert config.base_url == "http://[::1]:8000"
      assert Config.url(config, "/databases") == "http://[::1]:8000/v1/databases"
    end

    # `URI.parse/1` accepts all of these and quietly turns them into something
    # else. Config exists to reject bad configuration, not to launder it.
    for {url, expected} <- [
          {"http://host:abc", "A port must be numeric"},
          {"http://host:99999999", "outside 1..65535"},
          {"http://host:0", "outside 1..65535"},
          {"http://user:pw@host:8000", "Pass :username and :password instead"},
          {"http://[bad", "unbalanced brackets"},
          {"http://ho st:8000", "no spaces"},
          {"http://", "expected an http(s) URL"}
        ] do
      test "rejects #{inspect(url)}" do
        assert {:error, %Error{kind: :config, message: message}} =
                 Config.new(url: unquote(url), token: "t")

        assert message =~ unquote(expected)
        assert message =~ inspect(unquote(url))
      end
    end
  end

  describe "new/1 credentials" do
    test "accepts username and password" do
      assert {:ok, config} = Config.new(username: "admin", password: "password")
      assert config.username == "admin"
      assert config.static_token == nil
    end

    test "accepts a pre-issued token" do
      assert {:ok, config} = Config.new(token: "abc")
      assert config.static_token == "abc"
    end

    test "rejects missing credentials" do
      assert {:error, %Error{kind: :config, message: message}} = Config.new([])
      assert message =~ "missing credentials"
    end

    test "rejects a username without a password" do
      assert {:error, %Error{kind: :config}} = Config.new(username: "admin")
    end
  end

  describe "new/1 numeric options" do
    # These went through a bare Keyword.get/3, so `timeout: System.get_env(...)`
    # produced a connection that booted green and then failed every request from
    # inside the HTTP adapter, blaming Finch for a typo in the caller's config.
    for {key, bad, hint} <- [
          {:timeout, "5000", "positive integer"},
          {:timeout, 0, "positive integer"},
          {:timeout, -1, "positive integer"},
          {:connect_timeout, "1000", "positive integer"},
          {:max_retries, -1, "non-negative"},
          {:max_retries, 1.5, "non-negative"},
          {:max_auth_renewals, "2", "non-negative"},
          {:answer_count_limit, 0, "positive integer"},
          {:answer_count_limit, "100", "positive integer"}
        ] do
      test "rejects #{key}: #{inspect(bad)}" do
        assert {:error, %Error{kind: :config, message: message}} =
                 Config.new([{unquote(key), unquote(bad)}, {:token, "t"}])

        assert message =~ inspect(unquote(key))
        assert message =~ unquote(hint)
      end
    end

    test "accepts the documented values" do
      assert {:ok, config} =
               Config.new(
                 token: "t",
                 timeout: 1,
                 connect_timeout: :infinity,
                 max_retries: 0,
                 max_auth_renewals: 0,
                 answer_count_limit: 1
               )

      assert config.timeout == 1
      assert config.connect_timeout == :infinity
      assert config.max_retries == 0
      assert config.max_auth_renewals == 0
      assert config.answer_count_limit == 1
    end

    test "answer_count_limit is optional" do
      assert {:ok, %{answer_count_limit: nil}} = Config.new(token: "t")
    end
  end

  describe "new/1 unknown options" do
    test "a misspelled option is rejected rather than silently defaulted" do
      assert {:error, %Error{kind: :config, message: message}} =
               Config.new(token: "t", timout: 5_000)

      assert message =~ ":timout"
      assert message =~ ":timeout", "the message should list the accepted keys"
    end

    test "several unknown options are all named" do
      assert {:error, %Error{message: message}} = Config.new(token: "t", foo: 1, bar: 2)
      assert message =~ ":foo"
      assert message =~ ":bar"
    end

    test "every option known_options/0 advertises is actually accepted" do
      # known_options/0 is the list new/1 rejects against and the list the error
      # message shows the user, so an entry that new/1 would refuse would be a
      # lie in both places. Building a config out of the whole list proves it.
      opts =
        for key <- Config.known_options() do
          case key do
            :url -> {:url, "http://localhost:8000"}
            :username -> {:username, "admin"}
            :password -> {:password, "password"}
            :token -> {:token, nil}
            :name -> {:name, :some_conn}
            :timeout -> {:timeout, 1_000}
            :connect_timeout -> {:connect_timeout, 1_000}
            :http -> {:http, {TypeDB.HTTP.Httpc, []}}
            :max_retries -> {:max_retries, 1}
            :max_auth_renewals -> {:max_auth_renewals, 1}
            :answer_count_limit -> {:answer_count_limit, 10}
            :retry_backoff -> {:retry_backoff, {:exponential, 10}}
            :retry_max_delay -> {:retry_max_delay, 1_000}
            :deadline -> {:deadline, 30_000}
          end
        end

      assert {:ok, _} = Config.new(opts)
    end
  end

  describe "new/1 misc options" do
    test "rejects a non-atom name" do
      assert {:error, %Error{kind: :config, message: message}} =
               Config.new(token: "t", name: {:via, Registry, :x})

      assert message =~ "invalid :name"
    end

    test "rejects a bad http adapter spec" do
      assert {:error, %Error{kind: :config}} = Config.new(token: "t", http: "httpc")
    end

    test "normalises a bare http adapter module" do
      assert {:ok, config} = Config.new(token: "t", http: TypeDB.HTTP.Httpc)
      assert config.http_adapter == TypeDB.HTTP.Httpc
      assert config.http_opts == []
    end

    test "rejects a bad backoff spec" do
      assert {:error, %Error{kind: :config}} = Config.new(token: "t", retry_backoff: :fast)
    end

    test "applies defaults" do
      assert {:ok, config} = Config.new(token: "t")
      assert config.name == TypeDB
      assert config.base_url == "http://localhost:8000"
      assert config.timeout == 60_000
      assert config.connect_timeout == 10_000
      assert config.max_retries == 1
      assert config.retry_max_delay == 5_000
      assert config.deadline == :infinity
    end
  end

  describe "new!/1" do
    test "raises on invalid options" do
      assert_raise Error, ~r/missing credentials/, fn -> Config.new!([]) end
    end
  end

  describe "url building" do
    setup do
      {:ok, config: Config.new!(url: "http://localhost:8000", token: "t")}
    end

    test "versioned paths carry the api version", %{config: config} do
      assert Config.url(config, "/transactions/open") == "http://localhost:8000/v1/transactions/open"
    end

    test "raw paths do not", %{config: config} do
      assert Config.raw_url(config, "/health") == "http://localhost:8000/health"
    end
  end

  describe "backoff/2" do
    test "the exponential ceiling doubles with every attempt" do
      config = Config.new!(token: "t", retry_backoff: {:exponential, 100})

      for {attempt, ceiling} <- [{1, 100}, {2, 200}, {3, 400}] do
        delays = for _ <- 1..500, do: Config.backoff(config, attempt)
        assert Enum.all?(delays, &(&1 in 0..ceiling))

        # Asserting only the bound would pass for a function that always
        # returned zero, which is the opposite failure.
        assert Enum.max(delays) > div(ceiling, 2)
      end
    end

    test "two callers backing off at the same moment rarely wait the same time" do
      # The whole point: lockstep retries are what turns a blip into an outage.
      config = Config.new!(token: "t", retry_backoff: {:exponential, 100})
      pairs = for _ <- 1..200, do: {Config.backoff(config, 3), Config.backoff(config, 3)}

      collisions = Enum.count(pairs, fn {a, b} -> a == b end)
      assert collisions < 20
    end

    test "supports a custom function, used verbatim" do
      config = Config.new!(token: "t", retry_backoff: fn attempt -> attempt * 7 end)
      assert Config.backoff(config, 3) == 21
      assert Config.backoff(config, 3) == 21
    end

    test ":retry_max_delay caps the exponential ceiling" do
      # Without it, attempt 10 of {:exponential, 100} would draw from 0..51_200 —
      # a fifty-second sleep in the calling process.
      config = Config.new!(token: "t", retry_backoff: {:exponential, 100}, retry_max_delay: 750)

      for attempt <- 1..40 do
        assert Config.backoff(config, attempt) in 0..750
      end
    end

    test ":retry_max_delay caps a custom function too" do
      # One option answers "how long can this sleep for" completely, rather than
      # for two of the three ways a delay can be produced.
      config = Config.new!(token: "t", retry_backoff: fn _ -> 90_000 end, retry_max_delay: 400)
      assert Config.backoff(config, 1) == 400
    end

    test ":infinity opts out of the cap" do
      config =
        Config.new!(token: "t", retry_backoff: fn _ -> 90_000 end, retry_max_delay: :infinity)

      assert Config.backoff(config, 1) == 90_000
    end

    test "a very large attempt number neither overflows nor allocates" do
      # `attempt` is bounded only by :max_retries, which the user sets.
      config = Config.new!(token: "t", retry_backoff: {:exponential, 100})
      assert Config.backoff(config, 100_000) in 0..5_000
    end

    test "rejects a bad :retry_max_delay" do
      assert {:error, %Error{kind: :config, message: message}} =
               Config.new(token: "t", retry_max_delay: "5s")

      assert message =~ ":retry_max_delay"
    end
  end
end
