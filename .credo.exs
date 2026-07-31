%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Readability.MaxLineLength, max_length: 110},
          {Credo.Check.Design.TagTODO, exit_status: 0}
        ],
        disabled: [
          # This driver mirrors TypeDB's own module layout; nesting depth is
          # inherent to the API surface rather than accidental.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
