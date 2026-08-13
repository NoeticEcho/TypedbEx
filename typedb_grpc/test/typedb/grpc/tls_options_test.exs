defmodule TypeDB.GRPC.TLSOptionsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  What `tls: true` actually hands to `:ssl`.

  The integration TLS suite proves the driver refuses a certificate it should
  refuse. This proves the other half — that it accepts one it should accept —
  without needing a publicly-signed server to point at, by pinning the options
  and by measuring `:ssl`'s own behaviour once, here, so the reason those
  options exist is written down as a fact rather than as a claim.
  """

  alias TypeDB.GRPC.Config

  defp config(opts) do
    Config.new!(
      [
        name: :"tls_opts_#{System.unique_integer([:positive])}",
        address: "h:1729",
        username: "admin",
        password: "password"
      ] ++ opts
    )
  end

  describe ":ssl has no trust store of its own" do
    @tag :tls_trust_store
    test "verify_peer without cacerts refuses a certificate a public CA signed" do
      # The measurement this whole feature rests on. `tls: true` used to mean
      # exactly these options, so it could not connect to a server with a
      # perfectly good certificate — a failure that reads as "TLS is broken"
      # rather than "an option is missing".
      :ssl.start()
      host = ~c"repo.typedb.com"

      case :ssl.connect(host, 443, [verify: :verify_peer], 10_000) do
        {:error, _} ->
          trusted = [verify: :verify_peer, cacerts: :public_key.cacerts_get()]

          assert {:ok, socket} = :ssl.connect(host, 443, trusted, 10_000),
                 "the machine's trust store did not verify a public certificate"

          :ssl.close(socket)

        {:ok, socket} ->
          :ssl.close(socket)

          flunk("""
          :ssl verified a public certificate with no cacerts, which it did not do when
          TypeDB.GRPC.Config.ssl_options/1 was written. If OTP now supplies a default
          trust store, the cacerts this driver injects are redundant and the reasoning
          in that function is out of date.
          """)
      end
    end
  end

  describe "ssl_options/1" do
    test "tls: false asks for nothing" do
      assert {:ok, []} = Config.ssl_options(config(tls: false))
    end

    test "tls: true carries the machine's trust store" do
      assert {:ok, opts} = Config.ssl_options(config(tls: true))
      assert [_ | _] = certs = Keyword.fetch!(opts, :cacerts)
      # OTP hands them over as `{:cert, der, decoded}` rather than raw DER, which
      # `:ssl` accepts as-is; asserting the shape keeps a future OTP change from
      # passing something `:ssl` would reject.
      assert Enum.all?(certs, &match?({:cert, der, _} when is_binary(der), &1))
      refute Keyword.has_key?(opts, :verify), ":ssl's own verify_peer default is the point"
    end

    test "tls_root_ca replaces the store rather than adding to it" do
      path = write_pem()

      assert {:ok, opts} = Config.ssl_options(config(tls: true, tls_root_ca: path))
      assert Keyword.fetch!(opts, :cacertfile) == path
      refute Keyword.has_key?(opts, :cacerts), "a private CA means that CA, not that CA and 150 others"
    end

    test "an explicit cacertfile in tls_opts wins over tls_root_ca" do
      one = write_pem()
      other = write_pem()

      assert {:ok, opts} =
               Config.ssl_options(config(tls: true, tls_root_ca: one, tls_opts: [cacertfile: other]))

      assert Keyword.fetch!(opts, :cacertfile) == other
    end

    test "an explicit cacerts in tls_opts stops the store being read" do
      assert {:ok, opts} = Config.ssl_options(config(tls: true, tls_opts: [cacerts: [<<1, 2, 3>>]]))
      assert Keyword.fetch!(opts, :cacerts) == [<<1, 2, 3>>]
    end

    test "verify_none is left alone, because somebody meant it" do
      assert {:ok, opts} = Config.ssl_options(config(tls: true, tls_opts: [verify: :verify_none]))
      assert opts == [verify: :verify_none]
      refute Keyword.has_key?(opts, :cacerts)
    end

    test "other tls_opts survive alongside the store" do
      assert {:ok, opts} = Config.ssl_options(config(tls: true, tls_opts: [depth: 3]))
      assert Keyword.fetch!(opts, :depth) == 3
      assert Keyword.has_key?(opts, :cacerts)
    end
  end

  describe "the URL's scheme is an instruction" do
    defp from_url(url, opts \\ []) do
      Config.new!(
        [name: :"url_#{System.unique_integer([:positive])}", url: url, username: "a", password: "b"] ++
          opts
      )
    end

    test "https means TLS" do
      # The scheme used to be read for the host and the port and then thrown
      # away, so a URL that said https connected in clear text — a downgrade the
      # user had explicitly asked not to have.
      assert from_url("https://typedb.example.com").tls
      assert from_url("https://typedb.example.com:1730").tls
    end

    test "http does not" do
      refute from_url("http://localhost:8000").tls
    end

    test "an explicit :tls wins either way" do
      refute from_url("https://typedb.example.com", tls: false).tls
      assert from_url("http://typedb.example.com", tls: true).tls
    end

    test "an address without a scheme is plaintext, as before" do
      config = Config.new!(name: :url_plain, address: "typedb.example.com:1729", username: "a", password: "b")
      refute config.tls
    end

    test "https also settles the plaintext warning" do
      refute Config.plaintext_to_remote?(from_url("https://typedb.example.com"))
      assert Config.plaintext_to_remote?(from_url("http://typedb.example.com"))
    end
  end

  describe "tls_root_ca is checked at start-up" do
    test "a path that is not there fails the config, not the handshake" do
      assert_raise TypeDB.Error, ~r/no such file/, fn ->
        config(tls: true, tls_root_ca: "/definitely/not/here.pem")
      end
    end

    test "something that is not a path is rejected" do
      assert_raise TypeDB.Error, ~r/expected a path/, fn ->
        config(tls: true, tls_root_ca: :native)
      end
    end
  end

  defp write_pem do
    path = Path.join(System.tmp_dir!(), "typedb_grpc_ca_#{System.unique_integer([:positive])}.pem")
    File.write!(path, "-----BEGIN CERTIFICATE-----\nnot a real one\n-----END CERTIFICATE-----\n")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
