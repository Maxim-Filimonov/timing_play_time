defmodule TimingPlayTime.Vault do
  @moduledoc """
  Cloak vault used to encrypt Integration credentials at rest (ADR-0007).
  """

  use Cloak.Vault, otp_app: :timing_play_time
end
