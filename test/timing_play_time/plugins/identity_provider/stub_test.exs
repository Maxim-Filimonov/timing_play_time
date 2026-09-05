defmodule TimingPlayTime.Plugins.IdentityProvider.StubTest do
  use ExUnit.Case, async: false

  alias TimingPlayTime.Plugins.IdentityProvider.Stub

  setup do
    on_exit(fn -> Application.delete_env(:timing_play_time, :identity_provider_stub_result) end)
  end

  describe "authorization_url/1" do
    test "returns a callback URL with a state, and the state in session_params" do
      assert {:ok, url, %{state: state}} = Stub.authorization_url(redirect_uri: "http://x/cb")

      assert url =~ "/auth/callback?code=stub-code&state="
      assert url =~ state
    end

    test "errors when redirect_uri is missing" do
      assert Stub.authorization_url([]) == {:error, :missing_redirect_uri}
    end
  end

  describe "verify_callback/3" do
    test "returns the queued stub result on a matching state" do
      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      assert Stub.verify_callback(%{"state" => "s"}, %{state: "s"}, []) ==
               {:ok, %{sub: "email|abc", email: "a@b.com"}}
    end

    test "returns :state_mismatch when the state doesn't match" do
      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      assert Stub.verify_callback(%{"state" => "wrong"}, %{state: "s"}, []) ==
               {:error, :state_mismatch}
    end

    test "returns an :auth0 error when the params carry one" do
      assert Stub.verify_callback(%{"error" => "access_denied"}, %{state: "s"}, []) ==
               {:error, {:auth0, "access_denied"}}
    end
  end
end
