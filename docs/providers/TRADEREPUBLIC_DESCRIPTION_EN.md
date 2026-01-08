# Trade Republic Provider – Description

## Overview

The Trade Republic provider enables automatic synchronization of Trade Republic accounts and transactions into the Sure application, using an unofficial WebSocket integration.

## Key Features

- **2FA Authentication**: Secure login with phone number, PIN, and code received from the Trade Republic app.
- **Session Management**: Encrypted storage of tokens and cookies, support for processId in the authentication flow.
- **Account & Transaction Import**: Fetches portfolio, balances, and transaction history via WebSocket.
- **Automated Sync**: Manual or Sidekiq-triggered sync, orchestrated by dedicated jobs and services.
- **Modular Architecture**: Dedicated models, services, jobs, and controllers, following Rails and project conventions.

## Technical Architecture

- **Main Models**: `TraderepublicItem` (connection), `TraderepublicAccount` (account), `Provider::Traderepublic` (WebSocket client).
- **Services**: Importer, Syncer, Processor for importing, syncing, and parsing data.
- **Jobs**: `TraderepublicItem::SyncJob` for background synchronization.
- **Security**: Credentials and tokens encrypted via ActiveRecord Encryption, strict handling of sensitive data.

## Limitations & Considerations

- Unofficial API: Subject to change, no automatic refresh token yet.
- Incomplete transaction and holdings parser: To be improved as needed.
- Blocking WebSocket: Uses EventMachine, may impact scalability.
- Manual authentication possible: Token extraction via browser if API issues occur.

## Deployment & Usage

- Required gems and migrations must be installed.
- ActiveRecord Encryption keys must be configured.
- Connection and sync tests via UI or Rails console.
- Monitoring via logs and Sidekiq.

## Related Documentation

- [Deployment Guide](docs/providers/TRADEREPUBLIC_DEPLOYMENT.md)
- [Quick Start](docs/providers/TRADEREPUBLIC_QUICKSTART.md)
- [Manual Authentication](docs/providers/TRADEREPUBLIC_MANUAL_AUTH.md)
- [Technical Documentation](docs/providers/TRADEREPUBLIC.md)

---

Feel free to adapt or extend this according to your PR context or documentation target.
