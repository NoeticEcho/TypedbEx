# Deliberately empty. Nothing in this project needs a dialyzer warning silenced.
#
# It used to hold two `:unknown_function` filters for `Decimal`, which the driver
# converts to and from only when the host application happens to depend on it.
# Declaring `{:decimal, ..., optional: true}` in mix.exs made the module visible
# to dialyzer here while still never forcing it on a consumer, so the filters
# became unnecessary — and `list_unused_filters: true` in mix.exs turns a stale
# filter into a failure, which is how that was noticed.
#
# Kept rather than deleted because mix.exs references it by path.
[]
