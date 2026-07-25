import Config

# Domain tests are fast and DB-free/network-free against the Stub adapters; the
# persistence contract-test suite exercises Sqlite directly, and the Timing
# adapter is exercised directly against ExMCP's test transport, regardless of
# these defaults.
config :timing_play_time,
  persistence_adapter: TimingPlayTime.Plugins.Persistence.Stub,
  time_source_adapter: TimingPlayTime.Plugins.TimeSource.Stub

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :timing_play_time, TimingPlayTime.Repo,
  database: Path.expand("../timing_play_time_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :timing_play_time, TimingPlayTimeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "sOfVvwDYy6MZ/bokYn7FWsnAEXcIuj8t7XZiOmpshsN2KnsXTqx5f2p+U6cr7Mop",
  server: false

# In test we don't send emails
config :timing_play_time, TimingPlayTime.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
