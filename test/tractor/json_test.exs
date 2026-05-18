defmodule Tractor.JSONTest do
  use ExUnit.Case, async: true

  alias Tractor.JSON

  describe "encode!/1" do
    test "encodes a binary that ends mid-codepoint without raising" do
      bad = <<"hello ", 0xE2, 0x80>>
      json = JSON.encode!(%{"text" => bad})

      decoded = Jason.decode!(json)
      assert is_binary(decoded["text"])
      assert decoded["text"] =~ "hello"
    end

    test "deeply-nested map: invalid leaf sanitized, structure preserved" do
      payload = %{
        "a" => %{
          "b" => %{
            "c" => [%{"text" => <<"ok", 0xE2>>}]
          }
        }
      }

      json = JSON.encode!(payload)
      decoded = Jason.decode!(json)

      [%{"text" => leaf}] = decoded["a"]["b"]["c"]
      assert is_binary(leaf)
      refute leaf == <<"ok", 0xE2>>
    end

    test "encodes a DateTime struct without sanitizing its internal fields" do
      dt = ~U[2026-05-18 12:00:00Z]
      json = JSON.encode!(%{"at" => dt})

      assert json =~ "2026-05-18T12:00:00Z"
    end

    test "round-trip preserves valid-UTF-8 strings byte-for-byte" do
      valid = "héllo — world ✓"
      decoded = JSON.encode!(%{"text" => valid}) |> Jason.decode!()
      assert decoded["text"] == valid
    end
  end

  describe "encode_to_iodata!/1" do
    test "produces iodata that round-trips through Jason.decode!" do
      iodata = JSON.encode_to_iodata!(%{"a" => 1, "b" => "two"})
      assert iodata |> IO.iodata_to_binary() |> Jason.decode!() == %{"a" => 1, "b" => "two"}
    end
  end

  describe "sanitize_payload/2" do
    test "leaves non-binary leaves untouched" do
      payload = %{"int" => 42, "float" => 1.5, "bool" => true, "nil" => nil, "atom" => :ok}
      assert JSON.sanitize_payload(payload) == payload
    end

    test "passes opts (printable_limit) through to Tractor.Text.sanitize/2" do
      huge = <<"x", 0xE2>> |> String.duplicate(1)
      out = JSON.sanitize_payload(%{"t" => huge}, printable_limit: 4)
      assert is_binary(out["t"])
    end
  end
end
