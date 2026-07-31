#!/usr/bin/env bash
set -euo pipefail

perl -pe '
  s#registry\.cloudflare\.com/[^/]+/#registry.cloudflare.com/<redacted-account>/#g;
  s#((?:Authorization|Proxy-Authorization):\s*Bearer\s+)[^[:space:]]+#$1<redacted-token>#gi;
  s#((?:X-Auth-Key|X-Auth-Email|X-Api-Key|Api-Key):\s*)[^[:space:]]+#$1<redacted-token>#gi;
  s#([?&](?:token|api_key|access_token|refresh_token|auth_token|key|private_key)=)[^&[:space:]]+#$1<redacted-token>#gi;
  s#("(?:token|api_key|access_token|refresh_token|auth_token|secret|client_secret|private_key)"\s*:\s*")[^"]*#$1<redacted-token>#gi;
  s#(CLOUDFLARE_ACCOUNT_ID=)[^[:space:]]+#$1<redacted-account>#g;
  s#((?:CLOUDFLARE_API_TOKEN|API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|AUTH_TOKEN|PRIVATE_KEY)=)[^[:space:]]+#$1<redacted-token>#g;
'
