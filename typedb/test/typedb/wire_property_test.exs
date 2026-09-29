defmodule TypeDB.WirePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # The boundary where TypeDB's wire format meets Elixir types is where every
  # subtle bug in this driver has actually been: a duration whose raw string
  # silently outlived an edit, a NaiveDateTime whose precision changed under a
  # round trip, a decimal that kept TypeQL's literal suffix when Decimal was
  # absent.
  #
  # Example-based tests find the cases somebody thought of. These are for the
  # nanosecond that rounds, the offset on the hour boundary, and the string with
  # the quote in it.
  #
  # What the generators are allowed to produce is decided by what a live TypeDB
  # accepts, not by what looks reasonable — see
  # `test/integration/datetime_tz_offset_integration_test.exs`, which pins the
  # measurements the generators below are drawn from.

  alias TypeDB.{Concept, DateTimeTZ, Duration, Error, Given}

  # ----------------------------------------------------------------------------
  # Generators
  # ----------------------------------------------------------------------------

  defp iso_duration do
    gen all(
          years <- integer(0..99),
          months <- integer(0..11),
          days <- integer(0..30),
          hours <- integer(0..23),
          minutes <- integer(0..59),
          seconds <- integer(0..59),
          nanos <- integer(0..999_999_999)
        ) do
      date =
        [{years, "Y"}, {months, "M"}, {days, "D"}]
        |> Enum.reject(fn {value, _unit} -> value == 0 end)
        |> Enum.map_join(fn {value, unit} -> "#{value}#{unit}" end)

      fraction =
        if nanos == 0,
          do: "",
          else: "." <> (nanos |> Integer.to_string() |> String.pad_leading(9, "0"))

      time =
        [{hours, "H"}, {minutes, "M"}, {"#{seconds}#{fraction}", "S"}]
        |> Enum.reject(fn {value, _unit} -> value == 0 end)
        |> Enum.map_join(fn {value, unit} -> "#{value}#{unit}" end)

      # "P" alone is not a duration; PT0S is the zero.
      case {date, time} do
        {"", ""} -> "PT0S"
        {date, ""} -> "P" <> date
        {date, time} -> "P" <> date <> "T" <> time
      end
    end
  end

  # Components rather than a wire string, so that rendering has to come from the
  # struct: `raw` is what makes the round trip above trivially true, and a
  # duration a caller *built* has no raw at all.
  #
  # The extremes are drawn explicitly. A uniform integer over a billion
  # nanoseconds picks 999_999_999 about never, and that is the value where the
  # fraction is nine digits and the carry into seconds is one away.
  defp duration_components do
    one_of([
      member_of([
        %Duration{},
        %Duration{nanos: 1},
        %Duration{nanos: 999_999_999},
        %Duration{nanos: 999_999_999_999_999_999},
        %Duration{months: 1},
        %Duration{months: 11},
        %Duration{months: 12},
        %Duration{months: 999_999_999},
        %Duration{days: 1},
        %Duration{days: 999_999_999},
        %Duration{months: 999_999_999, days: 999_999_999, nanos: 999_999_999_999_999_999}
      ]),
      gen all(
            months <- integer(0..100_000),
            days <- integer(0..100_000),
            nanos <- integer(0..86_399_999_999_999)
          ) do
        %Duration{months: months, days: days, nanos: nanos}
      end
    ])
  end

  # At least one component negative, which TypeDB has no way to store: TypeQL
  # rejects `P-1Y`, `-P1Y` and every other form.
  defp negative_duration do
    gen all(
          months <- integer(-1000..1000),
          days <- integer(-1000..1000),
          nanos <- integer(-1_000_000_000..1_000_000_000),
          any_negative? = months < 0 or days < 0 or nanos < 0,
          any_negative?
        ) do
      %Duration{months: months, days: days, nanos: nanos}
    end
  end

  # Year 1 to year 9999 — the range `NaiveDateTime` renders as ISO-8601 with a
  # four-digit year, which is the only shape TypeDB's parser takes. The two ends
  # are drawn explicitly, for the same reason as the durations above.
  defp naive_datetime do
    one_of([
      member_of([
        ~N[0001-01-01 00:00:00],
        ~N[1969-12-31 23:59:59.999999],
        ~N[1970-01-01 00:00:00.000000],
        ~N[9999-12-31 23:59:59.999999]
      ]),
      gen all(
            date <-
              integer(Date.to_gregorian_days(~D[0001-01-01])..Date.to_gregorian_days(~D[9999-12-31])),
            seconds <- integer(0..86_399),
            microsecond <- integer(0..999_999)
          ) do
        date
        |> Date.from_gregorian_days()
        |> NaiveDateTime.new!(Time.from_seconds_after_midnight(seconds))
        |> NaiveDateTime.add(microsecond, :microsecond)
      end
    ])
  end

  # Offsets TypeDB can render, measured rather than guessed: whole minutes,
  # strictly inside a day in either direction. `-23:59` and `+23:59` are the
  # ends, and `+24:00` is a TypeQL syntax error.
  defp utc_offset do
    one_of([
      member_of([0, 60, -60, 86_340, -86_340, 50_400, -43_200]),
      map(integer(-86_340..86_340), &(div(&1, 60) * 60))
    ])
  end

  # An offset carrying seconds. A time zone database hands these out for any
  # pre-1900 timestamp: Europe/London was -75 seconds from UTC until 1847.
  defp sub_minute_offset do
    gen all(
          minutes <- integer(-1439..1439),
          seconds <- integer(1..59),
          sign <- member_of([1, -1])
        ) do
      minutes * 60 + sign * seconds
    end
  end

  defp out_of_range_offset do
    gen all(seconds <- integer(86_400..8_640_000), sign <- member_of([1, -1])) do
      sign * div(seconds, 60) * 60
    end
  end

  defp time_zone do
    member_of(~w(Europe/London America/New_York Asia/Tokyo Australia/Eucla UTC Pacific/Chatham))
  end

  # Nine fractional digits, which is what TypeDB actually sends and what
  # `NaiveDateTime` cannot hold.
  defp nanosecond_wire_value do
    gen all(
          naive <- naive_datetime(),
          nanos <- integer(0..999_999_999),
          suffix <- one_of([map(time_zone(), &(" " <> &1)), map(utc_offset(), &offset_string/1)])
        ) do
      stamp = NaiveDateTime.to_iso8601(%{naive | microsecond: {0, 0}})
      fraction = nanos |> Integer.to_string() |> String.pad_leading(9, "0")

      {stamp <> "." <> fraction <> suffix, nanos}
    end
  end

  defp offset_string(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(seconds)
    pad = &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))

    sign <> pad.(div(total, 3600)) <> ":" <> pad.(div(rem(total, 3600), 60))
  end

  # ----------------------------------------------------------------------------
  # Duration
  # ----------------------------------------------------------------------------

  describe "Duration" do
    property "every duration TypeDB can send parses, and renders back byte for byte" do
      check all(wire <- iso_duration()) do
        duration = Duration.parse(wire)

        assert %Duration{} = duration, "#{wire} did not parse"
        assert Duration.to_iso8601(duration) == wire
      end
    end

    property "an edited duration renders from its components, not from the stale raw" do
      # The bug this catches lost every read-modify-write: `raw` won, silently,
      # and the original value went back to the server.
      check all(wire <- iso_duration(), extra <- integer(1..1000)) do
        edited = %{Duration.parse(wire) | days: Duration.parse(wire).days + extra}

        rendered = Duration.to_iso8601(edited)
        refute rendered == wire

        assert %Duration{days: days} = Duration.parse(rendered)
        assert days == edited.days
      end
    end

    property "a duration built from components survives its own rendering exactly" do
      # No `raw`, so `to_iso8601/1` has to render, and `parse/1` has to recover
      # the same three numbers from a string that regrouped them — months into
      # years and months, nanoseconds into hours, minutes and a fraction.
      check all(duration <- duration_components()) do
        rendered = Duration.to_iso8601(duration)
        reparsed = Duration.parse(rendered)

        assert %Duration{} = reparsed, "#{rendered} did not parse back"
        assert reparsed.months == duration.months
        assert reparsed.days == duration.days
        assert reparsed.nanos == duration.nanos
      end
    end

    property "a negative component is refused, not rendered" do
      # A frozen decision, and the module doc says why: TypeQL has no negative
      # duration in any form, so there is nothing to render and normalising
      # would send a value nobody asked for.
      check all(duration <- negative_duration()) do
        assert_raise Error, fn -> Duration.to_iso8601(duration) end

        error = catch_error(Duration.to_iso8601(duration))
        assert %Error{kind: :encode} = error
      end
    end

    property "a negative duration is refused through Given too, with the same error" do
      check all(duration <- negative_duration()) do
        assert %Error{kind: :encode} = catch_error(Given.encode(duration))
        assert %Error{kind: :encode} = catch_error(Given.encode_rows([%{"d" => duration}]))
      end
    end

    property "parsing is total: anything unparseable comes back as the string" do
      check all(junk <- string(:printable)) do
        case Duration.parse(junk) do
          %Duration{} -> :ok
          ^junk -> :ok
        end
      end
    end

    test "a negative duration on the wire is not read as one" do
      # TypeDB cannot send these, and the parser does not invent a meaning for
      # them: they come back as the string, which is what `parse/1` promises for
      # anything it does not understand.
      for wire <- ~w(P-1Y -P1Y PT-1S P-1Y-2M) do
        assert Duration.parse(wire) == wire
      end
    end
  end

  # ----------------------------------------------------------------------------
  # DateTimeTZ
  # ----------------------------------------------------------------------------

  describe "DateTimeTZ" do
    property "a zoned value round-trips through the wire form" do
      check all(naive <- naive_datetime(), zone <- time_zone()) do
        value = DateTimeTZ.new(naive, zone)
        reparsed = value |> DateTimeTZ.to_iso8601() |> DateTimeTZ.parse()

        assert %DateTimeTZ{time_zone: ^zone} = reparsed
        # Compared as instants: the wire always carries nine fractional digits,
        # so precision comes back as {_, 6} even when it went in as {_, 0}.
        assert NaiveDateTime.compare(reparsed.naive, naive) == :eq
      end
    end

    property "an offset value round-trips, and keeps the offset rather than a name" do
      check all(naive <- naive_datetime(), offset <- utc_offset()) do
        value = DateTimeTZ.new(naive, offset)
        reparsed = value |> DateTimeTZ.to_iso8601() |> DateTimeTZ.parse()

        assert %DateTimeTZ{time_zone: nil, utc_offset: ^offset} = reparsed
        assert NaiveDateTime.compare(reparsed.naive, naive) == :eq
      end
    end

    property "a nanosecond off the wire survives byte for byte, and only :naive loses it" do
      # The type promises two different things and it is worth stating which is
      # which. `raw` — and so `to_iso8601/1` — is identity, always. `:naive` is
      # a `NaiveDateTime`, which holds microseconds, so it loses the last three
      # digits and *exactly* those: the microsecond is a truncation, not a
      # rounding, and nothing else about the value moves.
      check all({wire, nanos} <- nanosecond_wire_value()) do
        value = DateTimeTZ.parse(wire)

        assert %DateTimeTZ{} = value, "#{wire} did not parse"
        assert DateTimeTZ.to_iso8601(value) == wire
        assert value.raw == wire

        assert value.naive.microsecond == {div(nanos, 1000), 6}
      end
    end

    property "a value built from a NaiveDateTime keeps every microsecond and invents no more" do
      # The other half of the same promise. `new/2` renders nine digits because
      # TypeDB does, but the three it adds are zeros — it does not pretend to a
      # precision the `NaiveDateTime` never had.
      check all(naive <- naive_datetime(), offset <- utc_offset()) do
        rendered = naive |> DateTimeTZ.new(offset) |> DateTimeTZ.to_iso8601()

        {microsecond, _precision} = naive.microsecond
        expected = microsecond |> Integer.to_string() |> String.pad_leading(6, "0")

        assert rendered =~ "." <> expected <> "000"
        assert DateTimeTZ.parse(rendered).naive.microsecond == {microsecond, 6}
      end
    end

    property "an offset that is not a whole number of minutes is refused" do
      # It used to be truncated, and a truncated offset is a timestamp that
      # means something else and says nothing about it. TypeDB rejects
      # `+00:01:15` as a syntax error, so there is no form to render it in.
      check all(naive <- naive_datetime(), offset <- sub_minute_offset()) do
        assert %Error{kind: :encode} = error = catch_error(DateTimeTZ.new(naive, offset))
        assert error.message =~ "whole minute"
      end
    end

    property "an offset at or beyond a day is refused" do
      # `+99:59` is what the old renderer produced for one of these, and TypeDB
      # answers with a TypeQL syntax error naming a column number.
      check all(naive <- naive_datetime(), offset <- out_of_range_offset()) do
        assert %Error{kind: :encode} = error = catch_error(DateTimeTZ.new(naive, offset))
        assert error.message =~ "23:59"
      end
    end

    property "parsing is total" do
      check all(junk <- string(:printable)) do
        case DateTimeTZ.parse(junk) do
          %DateTimeTZ{} -> :ok
          ^junk -> :ok
        end
      end
    end

    test "a leap second comes back as the string rather than a wrong instant" do
      # TypeDB will not send one — it answers `[LIT4] Invalid time with hour 23,
      # minute 59, second 60` for the literal — and `NaiveDateTime` has no way to
      # hold one. Degrading to the string is the documented behaviour for
      # anything the parser does not understand, and is the only honest answer
      # here: silently reading it as :59:59 would move the value.
      assert DateTimeTZ.parse("2016-12-31T23:59:60.000000000Z") ==
               "2016-12-31T23:59:60.000000000Z"

      assert Concept.cast("2016-12-31T23:59:60", "datetime") == "2016-12-31T23:59:60"
    end

    test "the ends of the offset range render, and the first step past them does not" do
      naive = ~N[2024-03-01 10:30:00]

      assert DateTimeTZ.new(naive, 86_340) |> to_string() =~ "+23:59"
      assert DateTimeTZ.new(naive, -86_340) |> to_string() =~ "-23:59"

      assert %Error{kind: :encode} = catch_error(DateTimeTZ.new(naive, 86_400))
      assert %Error{kind: :encode} = catch_error(DateTimeTZ.new(naive, -86_400))

      # The one that mattered: Europe/London's offset before 1847.
      assert %Error{kind: :encode} = catch_error(DateTimeTZ.new(~N[1800-01-01 00:00:00], -75))
    end
  end

  # ----------------------------------------------------------------------------
  # Given
  # ----------------------------------------------------------------------------

  describe "Given" do
    property "a string is encoded as data, whatever it contains" do
      # The whole point of the tagged wire form: TypeQL is never asked to parse
      # a value, so no value can escape into it.
      check all(value <- string(:printable)) do
        assert %{"kind" => "value", "valueType" => "string", "value" => ^value} =
                 Given.encode(value)
      end
    end

    property "encoding a row never loses a variable and never rewrites a value" do
      check all(
              row <-
                map_of(string(:alphanumeric, min_length: 1), string(:printable), max_length: 8)
            ) do
        encoded = Given.encode_row(row)

        assert Map.keys(encoded) |> Enum.sort() == Map.keys(row) |> Enum.sort()

        for {variable, value} <- row do
          assert encoded[variable]["value"] == value
        end
      end
    end

    property "every temporal value the driver claims to encode is accepted" do
      check all(
              value <-
                one_of([
                  naive_datetime(),
                  map(naive_datetime(), &NaiveDateTime.to_date/1),
                  map(iso_duration(), &Duration.parse/1),
                  bind(naive_datetime(), fn n -> map(time_zone(), &DateTimeTZ.new(n, &1)) end),
                  integer(),
                  float(),
                  boolean()
                ])
            ) do
        assert %{"kind" => "value", "valueType" => type} = Given.encode(value)
        assert is_binary(type)
      end
    end

    property "a DateTime is refused for an offset TypeDB cannot write" do
      # This is the path a caller reaches without ever naming an offset: a
      # `DateTime` built from a time zone database carries whatever offset that
      # zone had on that date, and before 1900 that is very often not a whole
      # number of minutes.
      check all(naive <- naive_datetime(), offset <- sub_minute_offset()) do
        datetime = %DateTime{
          year: naive.year,
          month: naive.month,
          day: naive.day,
          hour: naive.hour,
          minute: naive.minute,
          second: naive.second,
          microsecond: naive.microsecond,
          time_zone: "Europe/London",
          zone_abbr: "LMT",
          utc_offset: offset,
          std_offset: 0
        }

        assert %Error{kind: :encode} = catch_error(Given.encode(datetime))
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Concept
  # ----------------------------------------------------------------------------

  describe "Concept.cast/2" do
    @value_types ~w(boolean integer double string decimal date datetime datetime-tz duration)

    property "casting never raises, whatever the server sends" do
      # The moduledoc promises a future TypeDB value type will not break a
      # running application. That promise is only worth having if it survives
      # values that do not match their declared type.
      check all(
              value <- one_of([string(:printable), integer(), float(), boolean(), constant(nil)]),
              type <- one_of([member_of(@value_types), string(:alphanumeric, min_length: 1)])
            ) do
        Concept.cast(value, type)
      end
    end

    property "an integer at the edges of TypeDB's i64 casts to itself" do
      check all(
              value <-
                one_of([
                  member_of([-9_223_372_036_854_775_808, 9_223_372_036_854_775_807, 0, -1, 1]),
                  integer()
                ])
            ) do
        assert Concept.cast(value, "integer") === value
      end
    end

    property "a double the server could not render as a number comes back unchanged" do
      # TypeDB renders infinities and NaN as words, and there is no float to cast
      # them to. Handing back the string is what keeps the promise above; a
      # `String.to_float/1` here would take the application down.
      check all(word <- member_of(~w(Infinity -Infinity NaN inf nan))) do
        assert Concept.cast(word, "double") === word
      end
    end

    property "a parseable temporal value casts to its Elixir type" do
      check all(wire <- iso_duration()) do
        assert %Duration{} = Concept.cast(wire, "duration")
      end
    end

    property "a decimal loses TypeQL's suffix whether or not Decimal is loaded" do
      check all(units <- integer(0..999_999), cents <- integer(0..999_999)) do
        rendered = "#{units}.#{cents}"

        cast = Concept.cast(rendered <> "dec", "decimal")
        refute to_string(cast) =~ "dec"
        assert to_string(cast) == to_string(Concept.cast(rendered, "decimal"))
      end
    end
  end
end
