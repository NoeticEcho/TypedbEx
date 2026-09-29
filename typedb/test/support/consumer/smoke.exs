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

# Whether `Decimal` was there is resolved when `TypeDB.Concept` is compiled, but
# only in the direction that cannot change afterwards: compiled *without* it,
# the per-value check has to stay, because a consumer who adds the dependency
# later may or may not get the module recompiled. This is the only place that
# direction exists, so it is the only place it can be checked.
# No function reports which branch compiled; the dynamic one writes its cache
# key on first use and the compile-time one never does. Without `Decimal` the
# dynamic branch must be the one here.
:persistent_term.erase({TypeDB.Concept, :decimal?})
_ = TypeDB.Concept.cast("1.5dec", "decimal")
cached = :persistent_term.get({TypeDB.Concept, :decimal?}, :absent)

case loaded do
  [] -> false = cached
  _ -> :absent = cached
end

IO.puts("ok: optional dependencies loaded = #{inspect(loaded)}")
