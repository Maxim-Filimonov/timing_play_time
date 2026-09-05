defmodule TimingPlayTime.Plugins.IdentityProvider.Auth0 do
  @moduledoc """
  IdentityProvider adapter backed by Auth0's hosted Universal Login, via the
  generic OIDC library `oidcc` (ADR-0015) — not `oidcc_plug`'s plugs, so this
  seam stays swappable per ADR-0002.

  Uses the authorization-code flow with PKCE: the app generates and tracks
  its own `state` / `nonce` / PKCE verifier (`oidcc` does not do this for
  you), round-tripped through the Plug session between `authorization_url/1`
  and `verify_callback/3`.
  """

  @behaviour TimingPlayTime.Plugins.IdentityProvider

  require Logger

  @provider_worker __MODULE__.ProviderConfiguration

  @impl true
  def authorization_url(opts) do
    with {:ok, config} <- fetch_config() do
      redirect_uri = Keyword.fetch!(opts, :redirect_uri)
      login_hint = Keyword.get(opts, :login_hint)

      state = random_string()
      nonce = random_string()
      pkce_verifier = random_string()

      auth_opts =
        %{
          redirect_uri: redirect_uri,
          state: state,
          nonce: nonce,
          pkce_verifier: pkce_verifier,
          require_pkce: true,
          scopes: ["openid", "email"],
          url_extension: url_extension(login_hint)
        }

      @provider_worker
      |> Oidcc.create_redirect_url(config.client_id, config.client_secret, auth_opts)
      |> normalize_redirect_url()
      |> case do
        {:ok, url} -> {:ok, url, %{state: state, nonce: nonce, pkce_verifier: pkce_verifier}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # oidcc's `:uri_string.uri_string()` return type is `unicode:chardata()`,
  # not necessarily a plain binary — against a real Auth0 tenant it comes
  # back as an iolist. `redirect(external: url)` requires a binary
  # (`Plug.HTML.html_escape/1` pattern-matches `is_binary`), so every real
  # link/login click crashed with a FunctionClauseError without this.
  @doc false
  def normalize_redirect_url({:ok, url}), do: {:ok, IO.iodata_to_binary(url)}
  def normalize_redirect_url({:error, _reason} = error), do: error

  defp url_extension(nil), do: [{"connection", "email"}]
  defp url_extension(login_hint), do: [{"connection", "email"}, {"login_hint", login_hint}]

  @impl true
  def verify_callback(%{"error" => error} = params, _session_params, _opts) do
    Logger.warning("Auth0.verify_callback: Auth0 returned error=#{inspect(error)} description=#{inspect(params["error_description"])}")
    {:error, {:auth0, error}}
  end

  def verify_callback(params, session_params, opts) do
    with {:ok, config} <- fetch_config(),
         :ok <- verify_state(params, session_params),
         {:ok, code} <- fetch_code(params),
         redirect_uri <- Keyword.fetch!(opts, :redirect_uri),
         retrieve_opts <- %{
           redirect_uri: redirect_uri,
           nonce: Map.fetch!(session_params, :nonce),
           pkce_verifier: Map.fetch!(session_params, :pkce_verifier)
         },
         {:ok, token} <-
           Oidcc.retrieve_token(code, @provider_worker, config.client_id, config.client_secret, retrieve_opts) do
      claims = token.id.claims
      {:ok, %{sub: Map.fetch!(claims, "sub"), email: Map.fetch!(claims, "email")}}
    else
      {:error, reason} ->
        Logger.warning("Auth0.verify_callback: token exchange failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Auth0.verify_callback: exception during token exchange: #{inspect(error)}")
      {:error, {:exception, error}}
  end

  defp fetch_code(%{"code" => code}) when is_binary(code), do: {:ok, code}
  defp fetch_code(_params), do: {:error, :missing_code}

  # oidcc/retrieve_token doesn't check the callback's `state` against what
  # authorization_url/1 minted — that's the app's job (per this module's
  # moduledoc), so it's done here before ever exchanging the code, closing
  # off a login/link CSRF where an attacker's own valid code+state pair gets
  # replayed against a victim's pending session.
  defp verify_state(params, session_params) do
    if Map.get(params, "state") == Map.get(session_params, :state) do
      :ok
    else
      {:error, :state_mismatch}
    end
  end

  @doc """
  Starts the `oidcc` provider-configuration worker so `application.ex`'s
  `supervised_adapter_children/1` picks it up. `backoff_type: :exponential`
  (never `:stop`) so the app still boots when Auth0's `.well-known` is
  unreachable (ADR-0015's environments constraint).

  When `domain` isn't configured at all (a dev boot with no `.env` filled
  in yet — `config/runtime.exs` logs this at startup), starts nothing
  rather than an `oidcc` worker retrying forever against a garbage
  `https:///` issuer: there's no tenant to reach, so there's nothing useful
  to retry. The Link/Sign-in buttons still yield the generic failure via
  `fetch_config/0`'s ordinary `{:error, _}` return.
  """
  def child_spec(_opts) do
    case fetch_config() do
      {:ok, %{domain: domain}} when is_binary(domain) and domain != "" ->
        %{
          id: @provider_worker,
          start:
            {Oidcc.ProviderConfiguration.Worker, :start_link,
             [
               %{
                 issuer: "https://#{domain}/",
                 name: @provider_worker,
                 backoff_type: :exponential
               }
             ]}
        }

      _not_configured ->
        # A no-op child: starts, exits normally, and (restart: :temporary)
        # is never restarted — the supervisor treats it as done, not failed.
        %{id: @provider_worker, start: {Task, :start_link, [fn -> :ok end]}, restart: :temporary}
    end
  end

  defp fetch_config do
    case Application.get_env(:timing_play_time, __MODULE__) do
      nil -> {:error, :identity_provider_not_configured}
      config when is_list(config) -> {:ok, Map.new(config)}
    end
  end

  defp random_string do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
