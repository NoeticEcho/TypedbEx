defmodule TypeDB.DecimalResolutionTest do
  use ExUnit.Case, async: true

  # `TypeDB.Concept.cast/2` used to ask `:persistent_term`, once per value,
  # whether `Decimal` was available. That answer is now resolved when the module
  # is compiled — but only in the direction where it cannot change afterwards,
  # and this file is what says so rather than the comment saying so alone.
  #
  # The property that matters is not which branch compiled. It is that the
  # answer a caller gets does not depend on which branch compiled: the TypeQL
  # `dec` suffix is stripped either way, so an application that reads a decimal
  # as a string sees the same digits as one that reads it as a `Decimal`.

  alias TypeDB.Concept

  describe "however the decision was resolved" do
    test "the TypeQL literal suffix is stripped" do
      # The bug this prevents: without `Decimal` the fallback used to hand back
      # "12.345dec", so `Float.parse/1` on it, a comparison with it, or writing
      # it back all broke on a dependency being absent.
      refute to_string(Concept.cast("12.345dec", "decimal")) =~ "dec"
      assert to_string(Concept.cast("12.345dec", "decimal")) == "12.345"
    end

    test "a decimal that cannot be parsed comes back unchanged" do
      # `Decimal.new/1` raises on this, and `to_decimal/1` rescues into the
      # driver's standing promise: an unparseable value degrades rather than
      # taking the caller down.
      assert Concept.cast("not-a-number", "decimal") == "not-a-number"
    end

    test "a negative and a zero survive the round trip" do
      assert to_string(Concept.cast("-0.5dec", "decimal")) == "-0.5"
      assert to_string(Concept.cast("0dec", "decimal")) == "0"
    end
  end

  describe "the compile-time branch" do
    # No function reports which branch compiled — that would widen a surface
    # meant to freeze at 1.0. The dynamic branch writes its cache key on the
    # first call and the compile-time branch never does, so the key's absence
    # after a cast is the observation.

    test "is the one in this build, where Decimal is a test dependency" do
      assert Code.ensure_loaded?(Decimal)

      :persistent_term.erase({Concept, :decimal?})

      assert %Decimal{} = Concept.cast("1.5dec", "decimal")

      assert :persistent_term.get({Concept, :decimal?}, :absent) == :absent,
             "the decimal path still consults :persistent_term per value"
    end
  end
end
