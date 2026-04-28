defmodule Tractor.Init.SkillBundleTest do
  use ExUnit.Case, async: true

  alias Tractor.Init.SkillBundle

  test "files/0 returns the four bundle entries with bare basenames" do
    assert files = SkillBundle.files()
    assert Map.keys(files) |> Enum.sort() ==
             ["SKILL.md", "loop-patterns.md", "pipeline-reference.md", "validate-prompt.md"]

    Enum.each(files, fn {filename, contents} ->
      assert is_binary(contents), "#{filename} contents should be a binary"
      assert byte_size(contents) > 100, "#{filename} should not be empty"
    end)
  end

  test "SKILL.md path-rewrites docs/usage/X.md to bare basenames" do
    skill = SkillBundle.files()["SKILL.md"]

    refute skill =~ "docs/usage/pipeline-reference.md"
    refute skill =~ "docs/usage/validate-prompt.md"
    refute skill =~ "docs/usage/loop-patterns.md"

    assert skill =~ "pipeline-reference.md"
    assert skill =~ "validate-prompt.md"
    assert skill =~ "loop-patterns.md"
  end

  test "SKILL.md retains its YAML frontmatter so Claude Code can auto-discover it" do
    skill = SkillBundle.files()["SKILL.md"]

    assert String.starts_with?(skill, "---\n")
    assert skill =~ "name: create-pipeline"
    assert skill =~ "description:"
  end

  test "reference docs are pass-throughs (no path rewrites needed)" do
    files = SkillBundle.files()

    # The reference docs already cross-reference siblings as bare basenames,
    # so they should be byte-identical to the source files.
    assert files["pipeline-reference.md"] == File.read!("docs/usage/pipeline-reference.md")
    assert files["validate-prompt.md"] == File.read!("docs/usage/validate-prompt.md")
    assert files["loop-patterns.md"] == File.read!("docs/usage/loop-patterns.md")
  end

  test "name/0 is the bundle directory name" do
    assert SkillBundle.name() == "create-pipeline"
  end
end
