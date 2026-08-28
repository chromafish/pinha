import Config

# Pinha terminates plain HTTP; run it behind a TLS-terminating proxy or on a
# trusted network. Forcing SSL here would break git clients talking to the
# listener directly.
config :logger, level: :info
