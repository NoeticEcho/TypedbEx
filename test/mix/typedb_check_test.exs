defmodule Mix.Tasks.Typedb.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Typedb.Check

  @moduletag :tmp_dir
  @moduletag :typeql_check

  # The task shells out, which is the only place in the project that does. These
  # tests cover what that makes fragile: a schema too large to pass as an
  # argument, a filename full of shell metacharacters, and a machine with no
  # POSIX shell.
  #
  # Skipped, not silently passed, when the CLI is absent — a green test that did
  # not run is worse than no test.
  if is_nil(System.find_executable("typeql-check")) do
    @moduletag skip: "install the typeql-check CLI to run these"
  end

  setup %{tmp_dir: tmp_dir} do
    {:ok, dir: tmp_dir}
  end

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp run(argv) do
    capture_io(fn -> send(self(), {:result, safely(argv)}) end)
    receive do: ({:result, result} -> result)
  end

  # Per-file failures go to stderr, via Mix.shell().error/1. Safe to capture
  # globally because this module is async: false, and ExUnit runs sync modules
  # after the async ones have finished.
  defp capture_stderr(argv) do
    output = capture_io(:stderr, fn -> send(self(), {:result, safely(argv)}) end)
    receive do: ({:result, result} -> {result, output})
  end

  defp safely(argv) do
    Check.run(argv)
    :ok
  rescue
    error in Mix.Error -> {:raised, Exception.message(error)}
  end

  test "accepts a valid file", %{dir: dir} do
    write!(dir, "ok.tql", "define entity person;\n")

    assert :ok = run([Path.join(dir, "*.tql")])
  end

  test "reports a parse error and exits non-zero", %{dir: dir} do
    write!(dir, "bad.tql", "define entity ;\n")

    assert {{:raised, message}, output} = capture_stderr([Path.join(dir, "*.tql")])
    assert message =~ "failed to parse"
    assert output =~ "bad.tql"
    assert output =~ "syntax error"
  end

  # The whole reason the task feeds stdin rather than argv. Measured: this file
  # exits 7 (E2BIG) when passed as a command-line argument and 0 on stdin.
  test "handles a schema too large to pass as a command-line argument", %{dir: dir} do
    body = "define\n" <> Enum.map_join(1..40_000, "", &"  attribute attr#{&1}, value string;\n")
    path = write!(dir, "big.tql", body)

    assert byte_size(body) > 1_000_000, "the point of this test is exceeding ARG_MAX"

    # The old argv route, kept here so the test fails if the limit ever moves.
    assert {_output, status} =
             System.cmd(System.find_executable("typeql-check"), [body], stderr_to_stdout: true)

    assert status != 0, "argv accepted a #{byte_size(body)}-byte argument; stdin is no longer needed"

    assert :ok = run([path])
  end

  test "a filename that looks like shell syntax is data, not script", %{dir: dir} do
    # Every metacharacter that would matter if the path were interpolated into
    # the shell command rather than passed as a positional argument.
    name = "a b; echo pwned; $(echo sub) `echo tick` 'quoted'.tql"
    path = write!(dir, name, "define entity person;\n")

    assert :ok = run([path])

    # And the path reaches typeql-check intact. The name comes back byte for
    # byte — `$(echo sub)` still reading as `$(echo sub)` rather than `sub` is
    # the assertion: nothing was expanded, and nothing was split on the `;`.
    File.write!(path, "define entity ;\n")

    assert {{:raised, _}, output} = capture_stderr([path])
    assert output =~ name
    # The parse error proves it was *this* file that was read, not some fragment
    # of the name that happened to name something else.
    assert output =~ "syntax error"
  end

  test "says what to do when there is no POSIX shell", %{dir: dir} do
    path = write!(dir, "ok.tql", "define entity person;\n")

    # A PATH with typeql-check on it and no `sh`, which is what a bare Windows
    # install looks like.
    fake_bin = Path.join(dir, "bin")
    File.mkdir_p!(fake_bin)
    File.ln_s!(System.find_executable("typeql-check"), Path.join(fake_bin, "typeql-check"))

    real_path = System.get_env("PATH")

    try do
      System.put_env("PATH", fake_bin)

      assert {:raised, message} = run([path])
      assert message =~ "POSIX shell"
      assert message =~ "Git Bash"
    after
      System.put_env("PATH", real_path)
    end
  end
end
