defmodule Tractor.InitTest do
  use ExUnit.Case, async: true

  alias Tractor.Init

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "tractor-init-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp}
  end

  test "supported_agents/0 lists the three harnesses" do
    assert Init.supported_agents() == ["claude", "codex", "gemini"]
  end

  test "bundle_dir/2 produces .{agent}/skills/create-pipeline under the target", %{tmp: tmp} do
    assert Init.bundle_dir("claude", tmp) ==
             Path.join([tmp, ".claude", "skills", "create-pipeline"])

    assert Init.bundle_dir("codex", tmp) ==
             Path.join([tmp, ".codex", "skills", "create-pipeline"])

    assert Init.bundle_dir("gemini", tmp) ==
             Path.join([tmp, ".gemini", "skills", "create-pipeline"])
  end

  test "install/3 writes the four bundle files for claude", %{tmp: tmp} do
    assert {:ok, paths} = Init.install("claude", tmp)

    assert length(paths) == 4
    bundle = Init.bundle_dir("claude", tmp)
    assert File.exists?(Path.join(bundle, "SKILL.md"))
    assert File.exists?(Path.join(bundle, "pipeline-reference.md"))
    assert File.exists?(Path.join(bundle, "validate-prompt.md"))
    assert File.exists?(Path.join(bundle, "loop-patterns.md"))

    skill = File.read!(Path.join(bundle, "SKILL.md"))
    assert skill =~ "name: create-pipeline"
    refute skill =~ "docs/usage/"
  end

  test "install/3 works for codex and gemini under their own roots", %{tmp: tmp} do
    assert {:ok, _} = Init.install("codex", tmp)
    assert {:ok, _} = Init.install("gemini", tmp)

    assert File.exists?(Path.join([tmp, ".codex", "skills", "create-pipeline", "SKILL.md"]))
    assert File.exists?(Path.join([tmp, ".gemini", "skills", "create-pipeline", "SKILL.md"]))
  end

  test "install/3 refuses to overwrite an existing bundle dir without :force", %{tmp: tmp} do
    assert {:ok, _} = Init.install("claude", tmp)

    assert {:error, {:bundle_exists, dir}} = Init.install("claude", tmp)
    assert dir == Init.bundle_dir("claude", tmp)
  end

  test "install/3 with force: true overwrites the existing bundle", %{tmp: tmp} do
    assert {:ok, _} = Init.install("claude", tmp)
    assert {:ok, paths} = Init.install("claude", tmp, force: true)
    assert length(paths) == 4
  end

  test "install/3 rejects unknown agents", %{tmp: tmp} do
    assert {:error, {:unknown_agent, "kimi"}} = Init.install("kimi", tmp)
  end
end
