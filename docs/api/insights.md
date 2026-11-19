# Proactive insights API

`GET /api/v1/insights` returns the visible family feed. Reading this endpoint does
not change insight status. It requires `read` or `read_write` credentials and
preview features enabled for the authenticated user.

## Acknowledge an insight

`PATCH /api/v1/insights/{id}/acknowledge` takes the insight UUID in the path and no
request body. Authenticate with an OAuth bearer token or `X-Api-Key` carrying
`read_write` scope. Guests cannot modify the shared feed. Preview features must
be enabled for the authenticated user.

The action applies the same family and shared-account visibility rules as the
feed. It marks an active insight read, then acknowledges it, preserving an
existing read timestamp. Acknowledged insights disappear from the visible feed.
The stored acknowledgment state is `dismissed`; the model calls it acknowledged.

- `204 No Content`: acknowledged, already acknowledged, or already expired.
  Replays do not overwrite timestamps or revive an expired insight.
- `401`: missing or invalid credentials.
- `403`: insufficient write scope, guest access, or disabled preview features.
- `404`: unknown/malformed UUID, another family's insight, or an insight naming an
  account that is no longer visible to every active family member.

Acknowledgment covers the observation the user saw. The normal insight generator
may surface it again when its financial signal changes materially or in a new
reporting period. Clients should remove a row only after a successful response
and preserve a retry path on failure. See the generated OpenAPI document for the
wire contract.
