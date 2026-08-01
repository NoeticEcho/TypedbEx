defmodule TypeDB.TemporalTest do
  use ExUnit.Case, async: true

  alias TypeDB.{DateTimeTZ, Duration}

  doctest TypeDB.Duration
  doctest TypeDB.DateTimeTZ

  describe "Duration.parse/1" do
    test "full duration" do
      assert %Duration{months: 14, days: 3, nanos: nanos} = Duration.parse("P1Y2M3DT4H5M6S")
      assert nanos == (4 * 3600 + 5 * 60 + 6) * 1_000_000_000
    end

    test "date-only duration" do
      assert %Duration{months: 0, days: 5, nanos: 0} = Duration.parse("P5D")
    end

    test "time-only duration" do
      assert %Duration{months: 0, days: 0, nanos: 90_000_000_000} = Duration.parse("PT1M30S")
    end

    test "weeks fold into days" do
      assert %Duration{days: 14} = Duration.parse("P2W")
    end

    test "fractional seconds keep nanosecond precision" do
      assert %Duration{nanos: 1_500_000_000} = Duration.parse("PT1.5S")
      assert %Duration{nanos: 123_456_789} = Duration.parse("PT0.123456789S")
    end

    test "comma is accepted as a decimal separator" do
      assert %Duration{nanos: 1_500_000_000} = Duration.parse("PT1,5S")
    end

    test "the original string is preserved" do
      assert %Duration{raw: "P1Y"} = Duration.parse("P1Y")
    end

    test "zero duration" do
      assert %Duration{months: 0, days: 0, nanos: 0} = Duration.parse("PT0S")
    end

    test "rejects malformed input by returning it unchanged" do
      for input <- ["", "P", "1Y", "PT", "P1X", "PY", "PT1H2Y", "P1M1Y", "hello"] do
        assert Duration.parse(input) == input, "expected #{inspect(input)} to be rejected"
      end
    end

    test "from_iso8601/1" do
      assert {:ok, %Duration{days: 1}} = Duration.from_iso8601("P1D")
      assert :error = Duration.from_iso8601("nope")
    end
  end

  describe "Duration.to_iso8601/1" do
    test "returns the original string when parsed" do
      assert "P1Y2M3DT4H5M6S" == "P1Y2M3DT4H5M6S" |> Duration.parse() |> Duration.to_iso8601()
    end

    test "renders a constructed duration" do
      assert Duration.to_iso8601(%Duration{months: 14, days: 3}) == "P1Y2M3D"
      assert Duration.to_iso8601(%Duration{nanos: 3_661_000_000_000}) == "PT1H1M1S"
      assert Duration.to_iso8601(%Duration{}) == "PT0S"
      assert Duration.to_iso8601(%Duration{nanos: 1_500_000_000}) == "PT1.5S"
    end

    test "round-trips a constructed duration" do
      original = %Duration{months: 14, days: 3, nanos: 3_661_500_000_000}
      reparsed = original |> Duration.to_iso8601() |> Duration.parse()

      assert reparsed.months == original.months
      assert reparsed.days == original.days
      assert reparsed.nanos == original.nanos
    end

    # ISO-8601 has no per-component sign: %Duration{months: -14} used to render
    # as "P-1Y-2M", which parse/1 rejects and TypeDB would too.
    for {label, duration} <- [
          {"months", %Duration{months: -14}},
          {"days", %Duration{days: -1}},
          {"nanos", %Duration{nanos: -1}}
        ] do
      test "refuses to render a negative #{label} rather than emitting nonsense" do
        # TypeDB.Error, not ArgumentError: this is on the wire path via
        # TypeDB.Given.encode/1, so it surfaces out of TypeDB.query/4, and
        # everything that comes out of there is a TypeDB.Error. The kind is
        # :encode — an Elixir term that has no TypeDB wire value — and is part
        # of the frozen surface, so it is asserted rather than assumed.
        error =
          assert_raise TypeDB.Error, ~r/negative duration/, fn ->
            Duration.to_iso8601(unquote(Macro.escape(duration)))
          end

        assert error.kind == :encode
      end
    end

    test "a negative raw that no longer describes the components does not survive" do
      # The components are what the caller last said; `raw` is stale.
      assert_raise TypeDB.Error, fn ->
        Duration.to_iso8601(%Duration{months: -14, raw: "P-1Y-2M"})
      end
    end

    test "an unedited duration renders as the exact string TypeDB sent" do
      # Round-tripping the wire string is what preserves nanosecond precision
      # and TypeDB's own choice of units.
      for wire <- ["P1Y2M3DT4H5M6.123456789S", "PT0.5S", "P1M"] do
        assert wire |> Duration.parse() |> Duration.to_iso8601() == wire
      end
    end

    test "editing a component wins over the wire string it came from" do
      # Otherwise a read-modify-write silently writes the ORIGINAL value back.
      original = Duration.parse("P1Y")
      assert original.months == 12

      assert Duration.to_iso8601(%{original | months: 24}) == "P2Y"
      assert Duration.to_iso8601(%{original | days: 3}) == "P1Y3D"
      assert Duration.to_iso8601(%{original | nanos: 1_500_000_000}) == "P1YT1.5S"
    end
  end

  describe "DateTimeTZ.new/2" do
    # Before this, the only way to obtain a %DateTimeTZ{} was parse/1 on a string
    # TypeDB had already produced — so a consumer who wanted to *write* an
    # IANA-zoned value had to format the wire string by hand and stuff it in :raw.
    test "builds an IANA-zoned value in TypeDB's own wire format" do
      value = DateTimeTZ.new(~N[2024-03-01 10:30:00], "Europe/London")

      assert value.time_zone == "Europe/London"
      assert value.utc_offset == nil
      assert to_string(value) == "2024-03-01T10:30:00.000000000 Europe/London"
    end

    test "builds a fixed-offset value" do
      assert DateTimeTZ.new(~N[2024-03-01 10:30:00], 3600) |> to_string() ==
               "2024-03-01T10:30:00.000000000+01:00"

      assert DateTimeTZ.new(~N[2024-03-01 10:30:00], 0) |> to_string() ==
               "2024-03-01T10:30:00.000000000+00:00"

      assert DateTimeTZ.new(~N[2024-03-01 10:30:00], -18_000) |> to_string() ==
               "2024-03-01T10:30:00.000000000-05:00"

      # A half-hour zone: the minutes component has to be rendered, not dropped.
      assert DateTimeTZ.new(~N[2024-03-01 10:30:00], 19_800) |> to_string() ==
               "2024-03-01T10:30:00.000000000+05:30"
    end

    test "keeps sub-second precision" do
      assert DateTimeTZ.new(~N[2024-03-01 10:30:00.123456], 0) |> to_string() ==
               "2024-03-01T10:30:00.123456000+00:00"
    end

    test "what it builds is what parse/1 reads back" do
      for value <- [
            DateTimeTZ.new(~N[2024-03-01 10:30:00], "Europe/London"),
            DateTimeTZ.new(~N[2024-03-01 10:30:00.500000], 3600),
            DateTimeTZ.new(~N[2024-03-01 10:30:00], -18_000)
          ] do
        reparsed = value |> DateTimeTZ.to_iso8601() |> DateTimeTZ.parse()

        # compare/2, not ==: the wire format always carries nine fractional
        # digits, so a round trip normalises NaiveDateTime's precision
        # annotation from {0, 0} to {0, 6}. The instant is unchanged, which is
        # the property that matters.
        assert NaiveDateTime.compare(reparsed.naive, value.naive) == :eq
        assert reparsed.time_zone == value.time_zone
        assert reparsed.utc_offset == value.utc_offset
      end
    end
  end

  describe "DateTimeTZ" do
    test "parses an IANA zone" do
      value = DateTimeTZ.parse("2024-03-01T10:30:00.000000000 Europe/London")
      assert value.time_zone == "Europe/London"
      assert value.utc_offset == nil
      assert value.naive == ~N[2024-03-01 10:30:00.000000]
      assert value.raw == "2024-03-01T10:30:00.000000000 Europe/London"
    end

    test "parses a positive fixed offset" do
      value = DateTimeTZ.parse("2024-03-01T10:30:00.000000000+02:00")
      assert value.utc_offset == 7200
      assert value.time_zone == nil
    end

    test "parses a negative fixed offset" do
      assert %DateTimeTZ{utc_offset: -18_000} = DateTimeTZ.parse("2024-03-01T10:30:00.000000000-05:00")
    end

    test "parses Z as zero offset" do
      assert %DateTimeTZ{utc_offset: 0} = DateTimeTZ.parse("2024-03-01T10:30:00Z")
    end

    test "returns malformed input unchanged" do
      assert DateTimeTZ.parse("yesterday") == "yesterday"
      assert DateTimeTZ.parse("2024-03-01T10:30:00") == "2024-03-01T10:30:00"
    end

    test "to_datetime/1 converts a fixed offset to UTC" do
      value = DateTimeTZ.parse("2024-03-01T10:30:00+02:00")
      assert {:ok, datetime} = DateTimeTZ.to_datetime(value)
      assert datetime.time_zone == "Etc/UTC"
      assert DateTime.to_iso8601(datetime) == "2024-03-01T08:30:00Z"
    end

    test "to_datetime/1 on an IANA zone needs a time zone database" do
      value = DateTimeTZ.parse("2024-03-01T10:30:00.000000000 Europe/London")
      # No tz database is configured in the test suite, so this reports why.
      assert {:error, _reason} = DateTimeTZ.to_datetime(value)
    end

    test "String.Chars renders the wire form" do
      value = DateTimeTZ.parse("2024-03-01T10:30:00.000000000+02:00")
      assert to_string(value) == "2024-03-01T10:30:00.000000000+02:00"
      assert DateTimeTZ.to_iso8601(value) == "2024-03-01T10:30:00.000000000+02:00"
    end
  end
end
