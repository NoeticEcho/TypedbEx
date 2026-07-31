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
    test "grows exponentially from the base" do
      config = Config.new!(token: "t", retry_backoff: {:exponential, 100})
      assert Config.backoff(config, 1) == 100
      assert Config.backoff(config, 2) == 200
      assert Config.backoff(config, 3) == 400
    end

    test "supports a custom function" do
      config = Config.new!(token: "t", retry_backoff: fn attempt -> attempt * 7 end)
      assert Config.backoff(config, 3) == 21
    end
  end
end
