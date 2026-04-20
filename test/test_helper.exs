# Point Tractor.Config at a path that will never exist during tests so the
# project's real .tractor/config.toml doesn't leak into assertions.
Application.put_env(:tractor, :config_path, "/tmp/tractor-nonexistent-test-config.toml")

ExUnit.start()
