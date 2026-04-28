defmodule Tractor.Init.SkillBundle do
  @moduledoc """
  Compile-time bundle of the create-pipeline skill plus its three reference docs,
  baked into the escript so `tractor init` can install them anywhere without
  shipping a `priv/` payload.

  The skill at `skills/create-pipeline.md` references the docs as
  `docs/usage/<name>.md`. When installed into an agent's skills folder the docs
  sit alongside SKILL.md, so paths are rewritten to bare basenames at compile
  time (see `rewrite_skill_paths/1`).
  """

  @skill_source "skills/create-pipeline.md"
  @reference_source "docs/usage/pipeline-reference.md"
  @validate_source "docs/usage/validate-prompt.md"
  @loop_source "docs/usage/loop-patterns.md"

  @external_resource @skill_source
  @external_resource @reference_source
  @external_resource @validate_source
  @external_resource @loop_source

  @reference File.read!(@reference_source)
  @validate File.read!(@validate_source)
  @loop File.read!(@loop_source)

  @skill (
           [
             {"docs/usage/pipeline-reference.md", "pipeline-reference.md"},
             {"docs/usage/validate-prompt.md", "validate-prompt.md"},
             {"docs/usage/loop-patterns.md", "loop-patterns.md"}
           ]
           |> Enum.reduce(File.read!(@skill_source), fn {from, to}, acc ->
             String.replace(acc, from, to)
           end)
         )

  @doc """
  The map of bundle filename → file contents written by `tractor init`.

  Filenames are relative to the bundle root (e.g. `.claude/skills/create-pipeline/`).
  """
  @spec files() :: %{String.t() => String.t()}
  def files do
    %{
      "SKILL.md" => @skill,
      "pipeline-reference.md" => @reference,
      "validate-prompt.md" => @validate,
      "loop-patterns.md" => @loop
    }
  end

  @doc "The skill's logical name — used as the bundle directory name."
  @spec name() :: String.t()
  def name, do: "create-pipeline"
end
