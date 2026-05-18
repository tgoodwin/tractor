defmodule TractorWeb.StaticAssets do
  @moduledoc """
  Compile-time bundle of `priv/static`, baked into the escript / release so
  the observer can serve `/assets/*` regardless of the runtime cwd. Mirrors
  the approach in `Tractor.Init.SkillBundle`.
  """

  @static_root "priv/static"

  @files @static_root
         |> Path.join("**/*")
         |> Path.wildcard()
         |> Enum.filter(&File.regular?/1)

  for path <- @files do
    @external_resource path
  end

  @bundle (for path <- @files, into: %{} do
             rel = Path.relative_to(path, @static_root)
             {"/" <> rel, File.read!(path)}
           end)

  @spec fetch(String.t()) :: {:ok, binary()} | :error
  def fetch(request_path), do: Map.fetch(@bundle, request_path)

  @spec paths() :: [String.t()]
  def paths, do: Map.keys(@bundle)
end
