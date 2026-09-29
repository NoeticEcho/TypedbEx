defmodule TypeDB.Concept do
  @moduledoc """
  The concepts TypeDB returns inside `conceptRows` answers.

  Every entry in a row is one of:

  | Struct | TypeQL | Notes |
  | --- | --- | --- |
  | `TypeDB.Concept.Entity` | an entity instance | `iid`, optional `type` |
  | `TypeDB.Concept.Relation` | a relation instance | `iid`, optional `type` |
  | `TypeDB.Concept.Attribute` | an attribute instance | `iid`, `value`, `value_type`, optional `type` |
  | `TypeDB.Concept.Value` | a computed value | `value`, `value_type` |
  | `TypeDB.Concept.EntityType` | `entity` type | `label` |
  | `TypeDB.Concept.RelationType` | `relation` type | `label` |
  | `TypeDB.Concept.AttributeType` | `attribute` type | `label`, optional `value_type` |
  | `TypeDB.Concept.RoleType` | a relation role | `label` |
  | `nil` | an unbound optional variable | |
  | a list | a list-valued variable | elements are concepts |

  `type` is `nil` when the query ran with `include_instance_types: false`.

  ## Values

  `value` holds the value exactly as it came over the wire, which is what the
  HTTP API defines: JSON primitives for `boolean`, `integer`, `double` and
  `string`, and strings for `decimal`, `date`, `datetime`, `datetime-tz` and
  `duration`.

  Use `typed_value/1` to convert to native Elixir terms:

      iex> attr = %TypeDB.Concept.Attribute{iid: "0x1", value: "2024-03-01", value_type: "date"}
      iex> TypeDB.Concept.typed_value(attr)
      ~D[2024-03-01]

  Conversion never loses information: `datetime-tz` and `duration` become
  `TypeDB.DateTimeTZ` and `TypeDB.Duration` structs, which keep the original
  wire form alongside the parsed fields.
  """

  alias TypeDB.{DateTimeTZ, Duration, Error}

  defmodule Entity do
    @moduledoc "An entity instance."
    @type t :: %__MODULE__{iid: String.t(), type: TypeDB.Concept.EntityType.t() | nil}
    @enforce_keys [:iid]
    defstruct [:iid, :type]
  end

  defmodule Relation do
    @moduledoc "A relation instance."
    @type t :: %__MODULE__{iid: String.t(), type: TypeDB.Concept.RelationType.t() | nil}
    @enforce_keys [:iid]
    defstruct [:iid, :type]
  end

  defmodule Attribute do
    @moduledoc "An attribute instance: an owned value with an identity."
    @type t :: %__MODULE__{
            iid: String.t(),
            value: term(),
            value_type: String.t(),
            type: TypeDB.Concept.AttributeType.t() | nil
          }
    @enforce_keys [:iid, :value, :value_type]
    defstruct [:iid, :value, :value_type, :type]
  end

  defmodule Value do
    @moduledoc "A computed value with no identity, e.g. the result of an expression."
    @type t :: %__MODULE__{value: term(), value_type: String.t()}
    @enforce_keys [:value, :value_type]
    defstruct [:value, :value_type]
  end

  defmodule EntityType do
    @moduledoc "An entity type."
    @type t :: %__MODULE__{label: String.t()}
    @enforce_keys [:label]
    defstruct [:label]
  end

  defmodule RelationType do
    @moduledoc "A relation type."
    @type t :: %__MODULE__{label: String.t()}
    @enforce_keys [:label]
    defstruct [:label]
  end

  defmodule AttributeType do
    @moduledoc "An attribute type. `value_type` is `nil` for abstract attribute types."
    @type t :: %__MODULE__{label: String.t(), value_type: String.t() | nil}
    @enforce_keys [:label]
    defstruct [:label, :value_type]
  end

  defmodule RoleType do
    @moduledoc ~S(A role type. Labels are scoped, e.g. `"employment:employee"`.)
    @type t :: %__MODULE__{label: String.t()}
    @enforce_keys [:label]
    defstruct [:label]
  end

  @type instance :: Entity.t() | Relation.t() | Attribute.t()
  @type type :: EntityType.t() | RelationType.t() | AttributeType.t() | RoleType.t()
  @type t :: instance() | type() | Value.t()

  @typedoc "A row entry: a concept, an unbound variable, or a list of concepts."
  @type entry :: t() | nil | [t()]

  # Decodes one wire-format row entry into concept structs, raising
  # `TypeDB.Error` with `kind: :decode` when the payload does not look like
  # anything the HTTP API can produce.
  #
  # Internal since 0.11.0. `TypeDB.Answer.decode/1` and
  # `TypeDB.ConceptRow.decode/1` — the two steps above this one — have always
  # been `@doc false`, and a caller reaches decoded concepts through
  # `TypeDB.ConceptRow.get/2`, never through here.
  @doc false
  @spec decode(term()) :: entry()
  def decode(nil), do: nil

  def decode(entries) when is_list(entries), do: Enum.map(entries, &decode/1)

  def decode(%{"kind" => "entity"} = map) do
    %Entity{iid: fetch!(map, "iid"), type: decode_optional_type(map)}
  end

  def decode(%{"kind" => "relation"} = map) do
    %Relation{iid: fetch!(map, "iid"), type: decode_optional_type(map)}
  end

  def decode(%{"kind" => "attribute"} = map) do
    %Attribute{
      iid: fetch!(map, "iid"),
      value: fetch!(map, "value"),
      value_type: fetch!(map, "valueType"),
      type: decode_optional_type(map)
    }
  end

  def decode(%{"kind" => "value"} = map) do
    %Value{value: fetch!(map, "value"), value_type: fetch!(map, "valueType")}
  end

  def decode(%{"kind" => "entityType"} = map), do: %EntityType{label: fetch!(map, "label")}
  def decode(%{"kind" => "relationType"} = map), do: %RelationType{label: fetch!(map, "label")}
  def decode(%{"kind" => "roleType"} = map), do: %RoleType{label: fetch!(map, "label")}

  def decode(%{"kind" => "attributeType"} = map) do
    %AttributeType{label: fetch!(map, "label"), value_type: Map.get(map, "valueType")}
  end

  def decode(other) do
    raise Error.new(:decode, "unrecognised TypeDB concept: #{inspect(other)}", body: other)
  end

  defp decode_optional_type(map) do
    case Map.get(map, "type") do
      nil -> nil
      type -> decode(type)
    end
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        raise Error.new(:decode, "TypeDB concept is missing the #{inspect(key)} field", body: map)
    end
  end

  @typedoc """
  What kind of thing a concept is, in one atom.

  The same eight the protocol distinguishes, spelled the way Elixir spells
  atoms — `:entity_type`, not `:entityType`.
  """
  @type category ::
          :entity
          | :relation
          | :attribute
          | :entity_type
          | :relation_type
          | :attribute_type
          | :role_type
          | :value

  @doc """
  What kind of thing a concept is.

  The counterpart of Rust's `Concept::get_category`, and the reason it is worth
  having in a language with pattern matching: a `case` on this is one line per
  branch, where matching the structs means knowing all eight module names.

      iex> TypeDB.Concept.category(%TypeDB.Concept.Entity{iid: "0x0", type: nil})
      :entity

      iex> TypeDB.Concept.category(%TypeDB.Concept.AttributeType{label: "name"})
      :attribute_type

  Rust's other thirty-odd accessors are deliberately not here. `try_get_integer`
  and its dozen siblings say in a method what `typed_value/1` says once, and
  `is_entity` is `match?(%Entity{}, concept)` — a predicate that reads worse
  than the match it wraps. What survives the translation is this, plus the three
  predicates below, which answer questions the struct name alone does not.
  """
  @spec category(t()) :: category()
  def category(%Entity{}), do: :entity
  def category(%Relation{}), do: :relation
  def category(%Attribute{}), do: :attribute
  def category(%EntityType{}), do: :entity_type
  def category(%RelationType{}), do: :relation_type
  def category(%AttributeType{}), do: :attribute_type
  def category(%RoleType{}), do: :role_type
  def category(%Value{}), do: :value

  @doc """
  Whether the concept is data rather than schema.

      iex> TypeDB.Concept.instance?(%TypeDB.Concept.Entity{iid: "0x0", type: nil})
      true

      iex> TypeDB.Concept.instance?(%TypeDB.Concept.EntityType{label: "person"})
      false
  """
  @spec instance?(t()) :: boolean()
  def instance?(concept), do: category(concept) in [:entity, :relation, :attribute]

  @doc """
  Whether the concept is a type.

      iex> TypeDB.Concept.type?(%TypeDB.Concept.RoleType{label: "friendship:friend"})
      true
  """
  @spec type?(t()) :: boolean()
  def type?(concept) do
    category(concept) in [:entity_type, :relation_type, :attribute_type, :role_type]
  end

  @doc """
  Whether the concept is a bare value — a computed one, belonging to no instance.

      iex> TypeDB.Concept.value?(%TypeDB.Concept.Value{value: 3, value_type: "integer"})
      true

  An attribute is not one: it *has* a value and is also a thing in the database.
  `value/1` and `typed_value/1` read both.
  """
  @spec value?(t()) :: boolean()
  def value?(concept), do: category(concept) == :value

  @doc """
  Returns the `iid` of an instance, or `nil` for types and values.
  """
  @spec iid(t()) :: String.t() | nil
  def iid(%Entity{iid: iid}), do: iid
  def iid(%Relation{iid: iid}), do: iid
  def iid(%Attribute{iid: iid}), do: iid
  def iid(_other), do: nil

  @doc """
  Returns the label of a type, or of the type of an instance when it was included.
  """
  @spec label(t()) :: String.t() | nil
  def label(%EntityType{label: label}), do: label
  def label(%RelationType{label: label}), do: label
  def label(%AttributeType{label: label}), do: label
  def label(%RoleType{label: label}), do: label
  def label(%Entity{type: type}), do: label_of(type)
  def label(%Relation{type: type}), do: label_of(type)
  def label(%Attribute{type: type}), do: label_of(type)
  def label(%Value{}), do: nil

  defp label_of(nil), do: nil
  defp label_of(type), do: label(type)

  @doc """
  Returns the wire-format value of an attribute or value concept, `nil` otherwise.
  """
  @spec value(t()) :: term()
  def value(%Attribute{value: value}), do: value
  def value(%Value{value: value}), do: value
  def value(_other), do: nil

  @doc """
  Returns the value converted to a native Elixir term.

    * `boolean` → `boolean`
    * `integer` → `integer`
    * `double` → `float`
    * `string` → `String.t()`
    * `decimal` → `Decimal.t()` when the optional `Decimal` library is loaded,
      otherwise a string. TypeDB renders decimals with TypeQL's literal suffix
      (`"12.345dec"`), which is stripped either way — the value differs in type
      when `Decimal` is absent, not in content. The suffix survives in
      `TypeDB.Concept.value/1`, which is the raw wire value
    * `date` → `Date.t()`
    * `datetime` → `NaiveDateTime.t()`
    * `datetime-tz` → `TypeDB.DateTimeTZ.t()`
    * `duration` → `TypeDB.Duration.t()`

  Values that cannot be parsed are returned unchanged rather than raising, so a
  future TypeDB value type never breaks a running application.
  """
  @spec typed_value(t()) :: term()
  def typed_value(%Attribute{value: value, value_type: value_type}), do: cast(value, value_type)
  def typed_value(%Value{value: value, value_type: value_type}), do: cast(value, value_type)
  def typed_value(_other), do: nil

  @doc """
  Casts a wire value given its TypeDB value type name.
  """
  @spec cast(term(), String.t()) :: term()
  def cast(value, "boolean") when is_boolean(value), do: value
  def cast(value, "integer") when is_integer(value), do: value
  def cast(value, "double") when is_float(value), do: value
  def cast(value, "double") when is_integer(value), do: value * 1.0
  def cast(value, "string") when is_binary(value), do: value

  def cast(value, "decimal") when is_binary(value) do
    # TypeDB renders decimals with TypeQL's literal suffix, e.g. "12.345dec".
    # Stripped either way: without `Decimal` the fallback used to hand back the
    # suffix too, so the same attribute was "12.345" as a Decimal and "12.345dec"
    # as a string, and anything the caller did with the string — Float.parse/1,
    # a comparison, writing it back — broke on a dependency being absent.
    value |> String.trim_trailing("dec") |> decimal_value()
  end

  def cast(value, "date") when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> value
    end
  end

  def cast(value, "datetime") when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> naive
      {:error, _} -> value
    end
  end

  def cast(value, "datetime-tz") when is_binary(value), do: DateTimeTZ.parse(value)
  def cast(value, "duration") when is_binary(value), do: Duration.parse(value)
  def cast(value, _value_type), do: value

  @compile {:no_warn_undefined, Decimal}

  # Whether `Decimal` is available is asked once — and in the common case, not
  # at run time at all.
  #
  # The question is expensive to ask per value: `Code.ensure_loaded?/1` is a
  # cached lookup for a module that *is* loaded and a code-server round trip for
  # one that is not. Measured over 50,000 casts: 1ms present, 1096ms absent.
  # Caching the answer in `:persistent_term` fixed that and left a smaller cost
  # behind — a `:persistent_term.get/2` per value, 0.035µs, about 8% of the
  # decimal path when `Decimal` is present and a third of it when it is not.
  # `bench/decimal.exs` measures both.
  #
  # So the lookup is resolved when this module is compiled, in the one direction
  # where the answer cannot change afterwards. `Decimal` present at compile time
  # cannot become absent at run time in any way that matters: it would take a
  # release that excludes it, and then `Decimal.new/1` raises
  # `UndefinedFunctionError`, which `to_decimal/1` already rescues into exactly
  # the answer the absent branch gives. Compiled *without* it, the dynamic check
  # stays, because a consumer who later adds the dependency may or may not get
  # this module recompiled — and being right is worth 0.035µs.
  @decimal_at_compile_time Code.ensure_loaded?(Decimal)

  if @decimal_at_compile_time do
    defp decimal_value(trimmed), do: to_decimal(trimmed)
  else
    defp decimal_value(trimmed) do
      if decimal_loaded?(), do: to_decimal(trimmed), else: trimmed
    end

    defp decimal_loaded? do
      case :persistent_term.get({__MODULE__, :decimal?}, :unasked) do
        :unasked ->
          loaded? = Code.ensure_loaded?(Decimal)
          :persistent_term.put({__MODULE__, :decimal?}, loaded?)
          loaded?

        loaded? ->
          loaded?
      end
    end
  end

  defp to_decimal(value) do
    Decimal.new(value)
  rescue
    _ -> value
  end
end
