defmodule TimingPlayTimeWeb.Plugs.CurrentUser do
  @moduledoc """
  Reads `user_id` from the session cookie, auto-provisioning a new
  `TimingPlayTime.Accounts.User` on first visit (ADR-0006) — there is no
  login, the cookie itself is the account. Assigns `:current_user`.
  """

  import Plug.Conn

  alias TimingPlayTime.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn |> get_session(:user_id) |> fetch_user() do
      nil -> provision(conn)
      user -> assign(conn, :current_user, user)
    end
  end

  defp fetch_user(nil), do: nil
  defp fetch_user(user_id), do: Accounts.get_user(user_id)

  defp provision(conn) do
    {:ok, user} = Accounts.create_user()

    conn
    |> put_session(:user_id, user.id)
    |> assign(:current_user, user)
  end
end
