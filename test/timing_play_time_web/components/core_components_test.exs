defmodule TimingPlayTimeWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  alias TimingPlayTimeWeb.CoreComponents

  describe "mask_email/1" do
    test "masks the local part, keeps the domain" do
      assert CoreComponents.mask_email("maxim@example.com") == "m•••m@example.com"
    end

    test "returns nil for nil" do
      assert CoreComponents.mask_email(nil) == nil
    end

    test "handles a single-character local part without crashing" do
      assert CoreComponents.mask_email("a@example.com") == "a@example.com"
    end
  end
end
