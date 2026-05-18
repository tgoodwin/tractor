defmodule Tractor.Init.MacListener do
  @moduledoc """
  Compile-time bundle of `file_system`'s `mac_listener` binary, extracted to a
  stable cache path at startup and pointed at via the
  `FILESYSTEM_FSMAC_EXECUTABLE_FILE` env var.

  Escripts can't expose `:code.priv_dir(:file_system)` as a real filesystem
  path, so without this the runner / observer can't watch directories for
  events on macOS — see fs_mac.ex:115.
  """

  require Logger

  @source Path.join(:code.priv_dir(:file_system), "mac_listener")
  @external_resource @source
  @bytes if File.regular?(@source), do: File.read!(@source), else: nil

  @env_var "FILESYSTEM_FSMAC_EXECUTABLE_FILE"

  @spec install!() :: :ok | :skip
  def install! do
    cond do
      :os.type() != {:unix, :darwin} -> :skip
      is_nil(@bytes) -> :skip
      System.get_env(@env_var) -> :skip
      true -> do_install()
    end
  end

  defp do_install do
    dest = cache_path()

    unless installed?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, @bytes)
      File.chmod!(dest, 0o755)
    end

    System.put_env(@env_var, dest)
    :ok
  rescue
    error ->
      Logger.warning("mac_listener install failed: #{inspect(error)}")
      :skip
  end

  defp cache_path do
    hash =
      :crypto.hash(:sha256, @bytes)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    Path.join([System.user_home!(), ".cache", "tractor", "mac_listener-#{hash}"])
  end

  defp installed?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size == byte_size(@bytes)
      _other -> false
    end
  end
end
