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

  alias TypeDB.{Concept, DateTimeTZ, Duration, Given}

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

  defp naive_datetime do
    gen all(
          date <- integer(Date.to_gregorian_days(~D[1970-01-01])..Date.to_gregorian_days(~D[2100-12-31])),
          seconds <- integer(0..86_399),
          microsecond <- integer(0..999_999)
        ) do
      date
      |> Date.from_gregorian_days()
      |> NaiveDateTime.new!(Time.from_seconds_after_midnight(seconds))
      |> NaiveDateTime.add(microsecond, :microsecond)
    end
  end

  # Offsets TypeDB can render: whole minutes, within a day.
  defp utc_offset, do: map(integer(-50_400..50_400), &(div(&1, 60) * 60))

  defp time_zone do
    member_of(~w(Europe/London America/New_York Asia/Tokyo Australia/Eucla UTC Pacific/Chatham))
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

    property "parsing is total: anything unparseable comes back as the string" do
      check all(junk <- string(:printable)) do
        case Duration.parse(junk) do
          %Duration{} -> :ok
          ^junk -> :ok
        end
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

    property "parsing is total" do
      check all(junk <- string(:printable)) do
        case DateTimeTZ.parse(junk) do
          %DateTimeTZ{} -> :ok
          ^junk -> :ok
        end
      end
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
