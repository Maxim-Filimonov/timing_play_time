defmodule TimingPlayTime.Encrypted.Map do
  @moduledoc """
  Ecto type for an encrypted-at-rest map column, used by
  `TimingPlayTime.Accounts.Integration.credentials` (ADR-0007).
  """

  use Cloak.Ecto.Map, vault: TimingPlayTime.Vault
end
