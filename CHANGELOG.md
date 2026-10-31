# Changelog

## Unreleased

### MCP OAuth scope migration

- Upgrading migrates public OAuth applications whose scope is exactly
  `read_write` to the MCP-only `mcp:read_write` scope. Client IDs and redirect URIs are
  preserved; existing connectors can reauthorize without being re-added.
  Clients that explicitly request `read_write` must request `mcp:read_write` instead.
- This also includes public `read_write` applications created manually by a
  super-admin at `/oauth/applications`, even if they were used for JSON API
  scripts. Their existing tokens keep their permissions, but newly authorized
  tokens will have MCP-only access. For JSON API integrations, use a Sure API
  key or a confidential OAuth application configured with the API scopes you
  need. Registering again through `/register` only grants MCP access.
- **Legacy MCP access ends January 20, 2027 at 00:00 UTC.** Before that instant,
  `/mcp` continues accepting existing `read_write` tokens. From that instant,
  tokens without `mcp:read_write` receive HTTP 403 `insufficient_scope` with instructions
  to reauthorize. Tokens with `mcp:read_write` remain accepted. Static `MCP_API_TOKEN`
  authentication is unaffected by this OAuth scope deadline.
- The migration changes application scopes, not existing access tokens,
  refresh tokens, or authorization grants. Existing `read_write` tokens retain
  their JSON API permissions, and refreshing them can retain those permissions.
  Revoke existing tokens or authorizations and reauthorize with `mcp:read_write` to remove
  that broader access. The MCP deadline does not revoke JSON API access.
- The data migration is irreversible: rollback cannot safely distinguish
  migrated applications from newly registered MCP applications.
- Read-only MCP authorization and legacy credential retirement are tracked in
  [#4628](https://github.com/we-promise/sure/issues/4628).
