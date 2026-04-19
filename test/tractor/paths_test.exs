defmodule Tractor.PathsTest do
  use ExUnit.Case, async: false

  alias Tractor.Paths

  setup do
    original_data = System.get_env("TRACTOR_DATA_DIR")
    original_xdg = System.get_env("XDG_DATA_HOME")

    on_exit(fn ->
      restore_env("TRACTOR_DATA_DIR", original_data)
      restore_env("XDG_DATA_HOME", original_xdg)
    end)
  end

  @tag :tmp_dir
  test "resolves data dir from TRACTOR_DATA_DIR first", %{tmp_dir: tmp_dir} do
    System.put_env("TRACTOR_DATA_DIR", Path.join(tmp_dir, "tractor-data"))
    System.put_env("XDG_DATA_HOME", Path.join(tmp_dir, "xdg"))

    assert Paths.data_dir([]) == Path.join(tmp_dir, "tractor-data")
  end

  @tag :tmp_dir
  test "builds run dir under explicit runs dir", %{tmp_dir: tmp_dir} do
    run_dir = Paths.run_dir(runs_dir: tmp_dir, run_id: "run-123")

    assert run_dir == Path.join(tmp_dir, "run-123")
  end

  @tag :tmp_dir
  test "atomically writes files in destination directory", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "artifact.txt")

    assert :ok = Paths.atomic_write!(path, "first")
    assert File.read!(path) == "first"
    assert :ok = Paths.atomic_write!(path, "second")
    assert File.read!(path) == "second"
    assert [] = Path.wildcard(Path.join(tmp_dir, ".artifact.txt.*.tmp"))
  end

  test "exposes reserved checkpoint path" do
    assert Paths.checkpoint_path("/runs/example") == "/runs/example/checkpoint.json"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
