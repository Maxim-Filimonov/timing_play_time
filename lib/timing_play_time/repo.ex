defmodule TimingPlayTime.Repo do
  use Ecto.Repo,
    otp_app: :timing_play_time,
    adapter: Ecto.Adapters.SQLite3
end
