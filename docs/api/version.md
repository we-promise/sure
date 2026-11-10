# Query the running version

`GET /api/v1/version` returns only the running Sure version and build commit:

```json
{"version":"2026.11.2","commit_sha":"0123456789abcdef0123456789abcdef01234567"}
```

By default, supply an `X-Api-Key` or OAuth bearer token with `read` or
`read_write` scope. Browser session cookies do not authenticate this API.
The signed-in user menu already displays the same version and commit.

```sh
curl --fail --header "X-Api-Key: $SURE_API_KEY" "$SURE_URL/api/v1/version"
```

The version comes from Sure's existing version metadata, not a lookup of the
latest GitHub release. In production, the commit comes from `BUILD_COMMIT_SHA`;
it is `null` if unavailable. Development versions may contain a prerelease suffix.
Responses use `Cache-Control: private, no-store`, including authentication errors.

## Optional anonymous access

Set `PUBLIC_VERSION_ENDPOINT=true` in the web application's environment and
restart/redeploy it to explicitly allow anonymous queries. Only the exact value
`true` enables access; unset or other values leave authentication required.
For Docker Compose, pass this variable through the web service's `environment`
section; putting it only in Compose's interpolation `.env` file is not enough.
This option affects only the version endpoint. Supplied credentials are still
validated, with normal scope and API-key rate-limit checks.

Public version and commit information makes deployment fingerprinting easier.
Enable this only when that disclosure is appropriate for the deployment.
This is not a health/readiness endpoint, and disabling public access does not
promise that version information cannot be inferred from other app assets.
