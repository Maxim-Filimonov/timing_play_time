defmodule TimingPlayTimeWeb.LiveAuth do
  @moduledoc """
  LiveView `on_mount` hook that assigns `:current_user` from the session's
  `user_id` (ADR-0006). The router's `TimingPlayTimeWeb.Plugs.CurrentUser`
  guarantees a `user_id` is already in the session by the time any LiveView
  mounts; a miss here only happens for a stale/tampered cookie, handled by
  redirecting back through the plug to reprovision.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias TimingPlayTime.Accounts

  def on_mount(:default, _params, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil -> {:halt, redirect(socket, to: "/")}
      user -> {:cont, assign(socket, :current_user, user)}
    end
  end
end
