defmodule TimingPlayTimeWeb.AuthController do
  @moduledoc """
  The Auth0 redirect round-trip (ADR-0015): `link` and `login` both send the
  browser off to Auth0's hosted Universal Login page, and `callback`
  processes the return trip. Every branch redirects — this controller never
  renders.

  Stateless across the redirect: the only transient state is
  `%{flow, params}` under the session key `:auth`, consumed and deleted on
  callback. One generic failure outcome covers the whole round-trip (Auth0
  unreachable, user abandonment, any callback error, token-exchange
  failure, or a valid identity that maps to no User).
  """

  use TimingPlayTimeWeb, :controller

  alias TimingPlayTime.Accounts

  import TimingPlayTimeWeb.CoreComponents, only: [mask_email: 1]

  require Logger

  @identity_provider Application.compile_env!(:timing_play_time, :identity_provider_adapter)

  @generic_failure "That didn't complete. Please try again."

  def link(conn, _params) do
    start_flow(conn, :link, ~p"/settings", login_hint: nil)
  end

  def login(conn, _params) do
    start_flow(conn, :login, ~p"/", login_hint: nil)
  end

  defp start_flow(conn, flow, error_redirect, opts) do
    case @identity_provider.authorization_url(Keyword.put(opts, :redirect_uri, callback_url(conn))) do
      {:ok, url, session_params} ->
        conn
        |> put_session(:auth, %{flow: flow, params: session_params})
        |> redirect(external: url)

      {:error, reason} ->
        Logger.warning("AuthController.#{flow}: authorization_url failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, @generic_failure)
        |> redirect(to: error_redirect)
    end
  end

  def callback(conn, params) do
    case get_session(conn, :auth) do
      nil ->
        generic_failure(conn, ~p"/")

      %{flow: flow, params: session_params} ->
        conn = delete_session(conn, :auth)

        case @identity_provider.verify_callback(params, session_params, redirect_uri: callback_url(conn)) do
          {:ok, claims} -> handle_verified(conn, flow, claims)
          {:error, reason} -> handle_failure(conn, flow, reason)
        end
    end
  end

  defp handle_verified(conn, :link, claims) do
    case Accounts.link_identity(conn.assigns.current_user, claims) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email linked.")
        |> redirect(to: ~p"/settings")

      {:error, :already_linked} ->
        masked = conn.assigns.current_user.email |> mask_email()

        conn
        |> put_flash(:error, "This Playtime is already linked to #{masked}.")
        |> redirect(to: ~p"/settings")

      {:error, :identity_taken} ->
        conn
        |> put_flash(
          :error,
          "That email is already linked to another Playtime, which can't be merged. Try a different email."
        )
        |> redirect(to: ~p"/settings")
    end
  end

  defp handle_verified(conn, :login, claims) do
    case Accounts.authenticate_identity(claims) do
      {:ok, authed_user} ->
        anon_user = conn.assigns.current_user

        # Only the *other* browser's throwaway anonymous User is a discard
        # candidate — signing into your own already-linked (but still-empty)
        # User must never delete the very account you're signing into.
        if anon_user.id != authed_user.id do
          Accounts.discard_if_empty(anon_user)
        end

        conn
        |> put_session(:user_id, authed_user.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Welcome back.")
        |> redirect(to: ~p"/")

      {:error, :no_user} ->
        generic_failure(conn, ~p"/")
    end
  end

  defp handle_failure(conn, flow, reason) do
    Logger.warning("AuthController.callback: verify_callback failed (flow=#{flow}): #{inspect(reason)}")
    generic_failure(conn, origin_for(flow))
  end

  defp origin_for(:link), do: ~p"/settings"
  defp origin_for(:login), do: ~p"/"

  defp generic_failure(conn, to) do
    conn
    |> put_flash(:error, @generic_failure)
    |> redirect(to: to)
  end

  defp callback_url(conn), do: url(conn, ~p"/auth/callback")
end
