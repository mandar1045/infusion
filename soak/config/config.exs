import Config

# GitHub's spec declares no auth: say how to send the token (as the README shows).
config :github_sdk, auth: :bearer, api_key: {:env, "GITHUB_TOKEN"}

config :logger, level: :warning
