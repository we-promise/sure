# ATTACK-SURFACE.md (template)

> Goal: keep a short, accurate map of what can be attacked and how it is protected.

## Service summary
- Name:
- Repo:
- Owner/team:
- Env(s): local / staging / prod

## Entry points
### Public HTTP
- Base URL(s):
- Reverse proxy / ingress:
- Auth method(s): (JWT, OAuth, session cookie, API key)

### Webhooks (inbound)
List all inbound webhooks and how they’re verified:
- Provider / path:
- Verification: (signature / secret token / none)
- Replay protection: (timestamp/nonce)
- Rate limiting: (edge/app)

### Background jobs / queues
- Queue tech:
- Who can enqueue jobs:

## Authentication & authorization
- User model / tenants:
- Access control strategy:
- Known sensitive endpoints:

## Data stores
- DB(s):
- Object store / file storage:
- Secrets storage:

## File uploads
- Endpoints:
- Allowed content-types:
- Validation: magic-bytes / size caps / AV scanning:

## Rate limiting & abuse controls
- Edge rate limiting:
- App rate limiting:
- Trusted proxy handling:

## Observability
- Audit logging:
- Security alerts:

## Hardening checklist
- [ ] Disable docs/openapi in prod
- [ ] Security headers
- [ ] CORS allowlist tight
- [ ] Webhooks authenticated
- [ ] Token revocation enforced
- [ ] Backups + restore tested
