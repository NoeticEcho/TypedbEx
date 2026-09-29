# Shared banner: every number this directory produces is only meaningful beside
# the machine and the versions that produced it, and a number quoted in
# CHANGELOG.md without them cannot be checked by anyone later.
#
# Loaded by the other scripts with `Code.require_file("machine.exs", __DIR__)`.

defmodule Bench.Machine do
  @spec banner() :: String.t()
  def banner do
    """
    #{cpu()} × #{:erlang.system_info(:logical_processors_available)} logical
    OTP #{:erlang.system_info(:otp_release)} / Elixir #{System.version()} / #{os()}
    typedb #{version(:typedb)}#{optional()}
    """
  end

  @spec puts() :: :ok
  def puts, do: IO.puts(banner())

  defp cpu do
    case File.read("/proc/cpuinfo") do
      {:ok, info} ->
        info
        |> String.split("\n")
        |> Enum.find_value("unknown CPU", fn line ->
          case String.split(line, ":", parts: 2) do
            ["model name" <> _, name] -> String.trim(name)
            _ -> nil
          end
        end)

      _ ->
        "unknown CPU"
    end
  end

  defp os do
    {family, name} = :os.type()
    "#{family}/#{name}"
  end

  defp optional do
    for module <- [Decimal, Finch, Req, Jason], Code.ensure_loaded?(module), into: "" do
      app = module |> Module.split() |> hd() |> String.downcase() |> String.to_atom()
      " · #{app} #{version(app)}"
    end
  end

  defp version(app) do
    case Application.spec(app, :vsn) do
      nil -> "?"
      vsn -> to_string(vsn)
    end
  end
end
