defmodule TimingPlayTime.Plugins.IdentityProvider.Stub do
  @moduledoc """
  Stub implementation of IdentityProvider for testing (ADR-0015).

  Stands in for the whole Auth0 round-trip: `authorization_url/1` mints a
  fake callback URL with a `state`, and `verify_callback/3` returns whatever
  `stub_next_result/1` last queued, after checking `state` the same way the
  real Auth0 adapter's callback would. Starts nothing — see
  `TimingPlayTime.Application`'s `supervised_adapter_children/1`.
  """

  @behaviour TimingPlayTime.Plugins.IdentityProvider

  @doc """
  Test control: sets what the NEXT `verify_callback/3` returns.
  """
  def stub_next_result(result) do
    Application.put_env(:timing_play_time, :identity_provider_stub_result, result)
    :ok
  end

  # `opts` always carries a `:redirect_uri` from `AuthController`; a caller
  # (or a test) that omits it is the one way this stub reports a failed
  # `authorization_url/1` — kept at the behaviour's full `{:ok, ...} |
  # {:error, _}` union, rather than a body the type checker folds to just
  # `{:ok, ...}`, the same tradeoff `TimeSource.Stub.connect/1` documents.
  @impl true
  def authorization_url(opts) do
    case Keyword.fetch(opts, :redirect_uri) do
      {:ok, _redirect_uri} ->
        state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        {:ok, "/auth/callback?code=stub-code&state=#{state}", %{state: state}}

      :error ->
        {:error, :missing_redirect_uri}
    end
  end

  @impl true
  def verify_callback(params, session_params, _opts) do
    cond do
      params["error"] -> {:error, {:auth0, params["error"]}}
      params["state"] != session_params[:state] -> {:error, :state_mismatch}
      true -> Application.get_env(:timing_play_time, :identity_provider_stub_result) || {:error, :no_stub_result}
    end
  end
end
