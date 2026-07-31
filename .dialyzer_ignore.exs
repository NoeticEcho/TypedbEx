[
  # `Decimal` is an optional integration: the driver converts to and from it when
  # the host application happens to depend on it, and never otherwise. Dialyzer
  # has no way to see a module that is deliberately absent.
  {"lib/typedb/concept.ex", :unknown_function},
  {"lib/typedb/given.ex", :unknown_function}
]
