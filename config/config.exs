import Config

# Real IANA zone conversion for V4 usage-limit resets ("resets 4pm (Europe/London)").
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

import_config "#{config_env()}.exs"
