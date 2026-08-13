defmodule Mix.Tasks.Typedb.Grpc.Gen do
  @shortdoc "Regenerates lib/protocol/ from TypeDB's .proto files"

  @moduledoc """
  Regenerates the protobuf and gRPC stub modules under `lib/protocol/`.

      mix typedb.grpc.gen 3.12.0
      mix typedb.grpc.gen --path /somewhere/typedb-protocol

  The generated modules are committed rather than built at compile time, and
  that is a deliberate trade. Generating them during the build would put
  `protoc` and a network fetch of `typedb-protocol` between this package and
  every one of its users, on every machine, forever — for output that changes
  only when TypeDB releases a new protocol. Committing it means the package
  installs like any other, and the cost is remembering to run this task.

  What it does *not* do is decide which protocol version is right. The version
  lives in `TypeDB.GRPC.Protocol.version/0`, next to the generated code it
  describes, and the integration suite checks it against whichever server it is
  pointed at — so a mismatch is a red test rather than a decoding failure in
  somebody's application.

  ## Requirements

  `protoc` and `protoc-gen-elixir` on `PATH`:

      mix escript.install hex protobuf
      # then add ~/.mix/escripts to PATH

  ## Options

    * `--path` — a checkout of `typedb-protocol` to generate from, instead of
      cloning the version given as an argument
    * `--out` — where to write, defaulting to `lib/protocol`
  """

  use Mix.Task

  @default_out "lib/protocol"
  @repo "https://github.com/typedb/typedb-protocol.git"

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [path: :string, out: :string])
    out = Path.expand(opts[:out] || @default_out, File.cwd!())

    ensure_executable!("protoc")
    ensure_executable!("protoc-gen-elixir")

    {source, cleanup} = source_checkout(opts[:path], args)

    try do
      generate(source, out)
      Mix.shell().info("Generated #{out} from #{source}")

      Mix.shell().info(
        "Update TypeDB.GRPC.Protocol.version/0 if the protocol version changed, " <>
          "then run the integration suite against a matching server."
      )
    after
      cleanup.()
    end
  end

  defp source_checkout(path, _args) when is_binary(path), do: {Path.expand(path), fn -> :ok end}

  defp source_checkout(nil, [version]) do
    dir = Path.join(System.tmp_dir!(), "typedb-protocol-#{version}-#{System.unique_integer([:positive])}")

    cmd!("git", ["clone", "--depth=1", "--branch", version, @repo, dir])
    {dir, fn -> File.rm_rf!(dir) end}
  end

  defp source_checkout(nil, _) do
    Mix.raise("give a protocol version (mix typedb.grpc.gen 3.12.0) or --path to a checkout")
  end

  defp generate(source, out) do
    protos = source |> Path.join("proto/*.proto") |> Path.wildcard() |> Enum.sort()

    if protos == [] do
      Mix.raise("no .proto files under #{Path.join(source, "proto")}")
    end

    _ = File.rm_rf!(out)
    :ok = File.mkdir_p!(out)

    # `--proto_path` is the checkout root because every import inside these
    # files is written as `proto/x.proto`.
    cmd!(
      "protoc",
      ["--elixir_out=plugins=grpc:#{out}", "--proto_path=#{source}"] ++
        Enum.map(protos, &Path.relative_to(&1, source))
    )
  end

  defp ensure_executable!(name) do
    unless System.find_executable(name) do
      Mix.raise("#{name} is not on PATH — see the moduledoc of this task")
    end
  end

  defp cmd!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise("#{command} exited with #{status}:\n#{output}")
    end
  end
end
