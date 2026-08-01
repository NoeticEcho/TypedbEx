# Compiling is most of the point, but not all of it: the driver also has to
# *work* on OTP alone. Run by the "Optional dependencies" job in CI.

expected = if System.get_env("WITH_OPTIONAL") == "1", do: [Decimal, Finch, Jason, Req], else: []
loaded = [Finch, Req, Decimal, Jason] |> Enum.filter(&Code.ensure_loaded?/1) |> Enum.sort()

^expected = loaded

# The httpc adapter is the one that must not need anything outside OTP. Port 9
# is discard/unassigned, so this reaches the transport layer and no further.
{:ok, _} =
  TypeDB.start_link(
    name: :bare,
    url: "http://127.0.0.1:9",
    token: "x",
    http: TypeDB.HTTP.Httpc,
    max_retries: 0,
    connect_timeout: 500
  )

{:error, %TypeDB.Error{kind: kind}} = TypeDB.Database.list(:bare)
true = kind in [:transport, :timeout]

# JSON without jason.
{:ok, %{"a" => 1}} = TypeDB.JSON.decode(~s({"a":1}))

# A decimal is a string without Decimal and a Decimal with it — but the TypeQL
# literal suffix is stripped either way, so the content does not depend on
# which dependencies happen to be installed.
# Matched as a value, never as `%Decimal{}` — a struct pattern of an absent
# module is a *compile* error, which is the very bug this project exists to
# catch, and which this file reproduced on its first run.
case TypeDB.Concept.cast("12.345dec", "decimal") do
  "12.345" -> [] = loaded
  decimal -> true = Decimal.equal?(decimal, Decimal.new("12.345"))
end

IO.puts("ok: optional dependencies loaded = #{inspect(loaded)}")
