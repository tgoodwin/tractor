defmodule Tractor.Init do
  @moduledoc """
  Install the create-pipeline skill bundle into a project for one of the
  supported agent harnesses (Claude Code, Codex, Gemini CLI).

  Each harness gets the same bundle layout, just under a different per-agent
  directory at the project root:

    .claude/skills/create-pipeline/
    .codex/skills/create-pipeline/
    .gemini/skills/create-pipeline/

  Layout inside the bundle:

    SKILL.md
    pipeline-reference.md
    validate-prompt.md
    loop-patterns.md

  Claude Code auto-discovers `.claude/skills/<name>/SKILL.md` by frontmatter.
  Codex and Gemini CLI don't have a first-class skill abstraction today, but
  the bundle is shaped consistently so an agent session can be pointed at the
  SKILL.md by hand or through a memory file (`AGENTS.md`, `GEMINI.md`).
  """

  alias Tractor.Init.SkillBundle

  @supported_agents ~w(claude codex gemini)

  @typedoc "Supported agent harness identifier."
  @type agent :: String.t()

  @doc "List of agent identifiers that `install/3` accepts."
  @spec supported_agents() :: [String.t()]
  def supported_agents, do: @supported_agents

  @doc """
  Install the skill bundle for `agent` rooted at `target_root`.

  Options:
    * `:force` — overwrite an existing bundle directory (default false)

  Returns `{:ok, [written_path]}` with absolute paths of written files,
  or `{:error, reason}` for one of:
    * `{:unknown_agent, agent}`
    * `{:bundle_exists, dir}` — bundle dir already exists and `force: false`
    * `{:write_failed, path, posix_reason}`
  """
  @spec install(agent(), Path.t(), keyword()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def install(agent, target_root, opts \\ [])
      when is_binary(agent) and is_binary(target_root) and is_list(opts) do
    force? = Keyword.get(opts, :force, false)

    with :ok <- check_agent(agent),
         bundle_dir = bundle_dir(agent, target_root),
         :ok <- check_collision(bundle_dir, force?),
         :ok <- File.mkdir_p(bundle_dir) do
      write_bundle(bundle_dir)
    end
  end

  @doc """
  The absolute path of the bundle directory for `agent` rooted at `target_root`.
  Pure — does not touch the filesystem.
  """
  @spec bundle_dir(agent(), Path.t()) :: Path.t()
  def bundle_dir(agent, target_root) when is_binary(agent) and is_binary(target_root) do
    target_root
    |> Path.expand()
    |> Path.join(".#{agent}")
    |> Path.join("skills")
    |> Path.join(SkillBundle.name())
  end

  defp check_agent(agent) do
    if agent in @supported_agents,
      do: :ok,
      else: {:error, {:unknown_agent, agent}}
  end

  defp check_collision(bundle_dir, force?) do
    cond do
      not File.exists?(bundle_dir) -> :ok
      force? -> :ok
      true -> {:error, {:bundle_exists, bundle_dir}}
    end
  end

  defp write_bundle(bundle_dir) do
    SkillBundle.files()
    |> Enum.reduce_while({:ok, []}, fn {filename, contents}, {:ok, written} ->
      path = Path.join(bundle_dir, filename)

      case File.write(path, contents) do
        :ok -> {:cont, {:ok, [path | written]}}
        {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, _reason} = error -> error
    end
  end
end
