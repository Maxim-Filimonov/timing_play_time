defmodule TimingPlayTime.Plugins.IdentityProvider do
  @moduledoc """
  Behaviour for the Auth0-gated identity round-trip (ADR-0015, ADR-0002).

  Auth0 is a gate, not a session: the app's own `Plug.Session` cookie
  (ADR-0006) is untouched by this behaviour. There is no in-app code-entry
  screen — the Login Code is entered on Auth0's hosted Universal Login page.
  """

  @type claims :: %{sub: String.t(), email: String.t()}

  @doc """
  Builds the URL to redirect the browser to, plus the opaque
  `session_params` the caller stashes in the Plug session and hands back to
  `verify_callback/3`.

  `opts`: `[redirect_uri: String.t(), login_hint: String.t() | nil]`.
  """
  @callback authorization_url(opts :: keyword()) ::
              {:ok, url :: String.t(), session_params :: map()} | {:error, term()}

  @doc """
  Exchanges the raw callback query params for verified claims. `params` is
  the callback query map (`%{"code"=>_, "state"=>_}` on success,
  `%{"error"=>_}` on an Auth0-side failure). `session_params` is what
  `authorization_url/1` returned, round-tripped through the session. `opts`:
  `[redirect_uri: String.t()]`.

  EVERY failure mode — Auth0 error param, bad/expired code, state/nonce/PKCE
  mismatch, clock skew, transport error — returns `{:error, term()}`; the
  caller maps every reason to one generic outcome.
  """
  @callback verify_callback(params :: map(), session_params :: map(), opts :: keyword()) ::
              {:ok, claims()} | {:error, term()}
end
