#!/usr/bin/env bash
# Generates the two SDKs the soak test uses, with Infusion from Hex.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf gen_host && mix new gen_host > /dev/null
sed -i.bak 's|# {:dep_from_hexpm, "~> 0.3.0"},|{:infusion, "~> 0.6.1"},|' gen_host/mix.exs
(cd gen_host && mix deps.get > /dev/null &&
  mix infusion.gen https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/api.github.com/api.github.com.json \
    --name GitHub --app github_sdk --out ../sdks/github &&
  mix infusion.gen https://docs.coingecko.com/openapi-specs/demo-api.json \
    --name CoinGecko --app coingecko --out ../sdks/coingecko)
rm -rf gen_host
mix deps.get
