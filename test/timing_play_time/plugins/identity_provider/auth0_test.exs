defmodule TimingPlayTime.Plugins.IdentityProvider.Auth0Test do
  use ExUnit.Case, async: false

  alias TimingPlayTime.Plugins.IdentityProvider.Auth0

  # Only the branches reachable without a live Auth0 tenant are covered here
  # — matching the Testing Decisions in issue #34's spec: `oidcc` itself, and
  # the full authorization_url/verify_callback success path that depends on
  # it, are exercised by the (certified) library and by the IdentityProvider
  # Stub standing in for the whole round-trip everywhere else in this app.
  # What's left, and testable in-process: config plumbing, and the two
  # failure branches (`error` param, missing `code`) that short-circuit
  # before ever touching `oidcc`.

  describe "with a configured Auth0 client" do
    setup do
      Application.put_env(:timing_play_time, Auth0,
        domain: "bogus.example.auth0.com",
        client_id: "id",
        client_secret: "secret",
        redirect_uri: "http://localhost:4000/auth/callback"
      )

      on_exit(fn -> Application.delete_env(:timing_play_time, Auth0) end)
    end

    test "child_spec/1 starts the provider-configuration worker with a non-:stop backoff_type" do
      %{start: {Oidcc.ProviderConfiguration.Worker, :start_link, [opts]}} = Auth0.child_spec([])

      assert opts.backoff_type == :exponential
      assert opts.issuer == "https://bogus.example.auth0.com/"
    end

    test "verify_callback/3 short-circuits on an Auth0 error param, never touching oidcc" do
      assert Auth0.verify_callback(%{"error" => "access_denied"}, %{}, redirect_uri: "http://x") ==
               {:error, {:auth0, "access_denied"}}
    end

    test "verify_callback/3 fails fast when the callback carries no code" do
      assert Auth0.verify_callback(%{"state" => "s"}, %{state: "s", nonce: "n", pkce_verifier: "v"},
               redirect_uri: "http://x"
             ) == {:error, :missing_code}
    end

    test "verify_callback/3 rejects a state that doesn't match the stashed session_params, never touching oidcc" do
      assert Auth0.verify_callback(
               %{"code" => "c", "state" => "attacker-state"},
               %{state: "the-real-state", nonce: "n", pkce_verifier: "v"},
               redirect_uri: "http://x"
             ) == {:error, :state_mismatch}
    end
  end

  describe "with no Auth0 client configured" do
    setup do
      Application.delete_env(:timing_play_time, Auth0)
      :ok
    end

    test "authorization_url/1 reports the missing config instead of calling oidcc" do
      assert Auth0.authorization_url(redirect_uri: "http://x") ==
               {:error, :identity_provider_not_configured}
    end

    test "verify_callback/3 reports the missing config instead of calling oidcc" do
      assert Auth0.verify_callback(%{"code" => "c", "state" => "s"}, %{nonce: "n", pkce_verifier: "v"},
               redirect_uri: "http://x"
             ) == {:error, :identity_provider_not_configured}
    end

    test "child_spec/1 starts nothing rather than an oidcc worker with a garbage issuer" do
      assert %{id: Auth0.ProviderConfiguration, start: {Task, :start_link, [_fun]}, restart: :temporary} =
               Auth0.child_spec([])
    end
  end

  describe "with an Auth0 client configured but blank (dev, .env not filled in yet)" do
    setup do
      Application.put_env(:timing_play_time, Auth0,
        domain: nil,
        client_id: nil,
        client_secret: nil,
        redirect_uri: nil
      )

      on_exit(fn -> Application.delete_env(:timing_play_time, Auth0) end)
    end

    test "child_spec/1 starts nothing rather than retrying against https:///" do
      assert %{id: Auth0.ProviderConfiguration, start: {Task, :start_link, [_fun]}, restart: :temporary} =
               Auth0.child_spec([])
    end
  end
end
