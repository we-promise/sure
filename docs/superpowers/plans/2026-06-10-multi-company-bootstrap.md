# Multi-Company Bootstrap Runbook

**Goal:** Create the four Risingstone/Mahetel company workspaces and two platform-wide super-admin users through an idempotent, operator-run bootstrap path.

**Current implementation status:** Implemented and committed. Treat the source files below as authoritative instead of copying implementation snippets into this runbook.

**Authoritative files:**

- `app/services/platform_bootstrap/multi_company_owners.rb`
  - Owns business logic for family/user creation.
  - Creates or updates the four configured families.
  - Creates or updates two owner users.
  - Assigns both owners to the primary family named `Risingstone infra pvt ltd`.
  - Uses a `requires_new: true` transaction.
  - Supports dry-run by validating writes, rolling back, and returning safe preview objects.
- `test/services/platform_bootstrap/multi_company_owners_test.rb`
  - Covers create, update/idempotency, dry-run rollback, password validation, and write-count behavior.
- `lib/tasks/platform_bootstrap.rake`
  - Provides `platform_bootstrap:multi_company_owners`.
  - Reads owner passwords from derived environment keys or hidden interactive prompts.
  - Rejects blank environment values.
  - Supports boolean `DRY_RUN` values such as `DRY_RUN=1` and `DRY_RUN=true`.

**Relevant commits:**

- `2f752725` - `test: cover multi-company owner bootstrap`
- `b5582371` - `test: assert bootstrap errors avoid partial writes`
- `83c64b1a` - `test: enforce bootstrap write counts`
- `1b957569` - `feat: add multi-company owner bootstrap service`
- `77cec45b` - `fix: match bootstrap password rules to registration`
- `da290957` - `fix: return safe dry-run bootstrap previews`
- `5b5cab8a` - `feat: add multi-company owner bootstrap task`
- `a3bf35aa` - `fix: harden bootstrap task dry-run handling`
- `6f31c995` - `fix: derive bootstrap password env keys`

## Local Verification

Run the focused service and model tests:

```bash
rtk bin/rails test test/services/platform_bootstrap/multi_company_owners_test.rb test/models/user_test.rb test/models/family_test.rb
```

Expected: all tests pass.

Run a local dry-run through the rake task from an interactive shell:

```bash
rtk env DRY_RUN=1 bin/rails platform_bootstrap:multi_company_owners
```

Expected:

```text
Password for adminF0@bookeepz.net:
Password for adminF1@bookeepz.net:
Multi-company owner bootstrap validated in dry-run mode.
Families:
  - Risingstone infra pvt ltd
  - Risingstone ventures pvt ltd
  - Risingstone projects pvt Ltd
  - Mahetel pvt ltd
Users:
  - adminf0@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
  - adminf1@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
```

The password input should not echo in the terminal. Password values should be entered through hidden interactive prompts, not written to `.env`, shell history, tracked files, or long-lived service variables for a one-time bootstrap.

Verify dry-run did not write records:

```bash
rtk bin/rails runner 'puts({ families: Family.where(name: PlatformBootstrap::MultiCompanyOwners::COMPANY_NAMES).count, users: User.where(email: %w[adminf0@bookeepz.net adminf1@bookeepz.net]).count }.inspect)'
```

Expected in a database with no prior bootstrap records:

```text
{:families=>0, :users=>0}
```

If local fixtures or prior manual data already contain these records, expected counts should reflect the pre-existing state exactly and must not increase after dry-run.

## Production Execution

### Step 1: Confirm the Railway target

Run:

```bash
rtk env RAILWAY_CALLER=skill:use-railway@1.2.5 RAILWAY_AGENT_SESSION=railway-skill-sure-bootstrap railway status --json
```

Confirm the JSON shows the intended target before continuing:

```text
project: stellar-enjoyment
environment: production
service: sure-web
```

If the project, environment, or service differs, stop and switch to the correct Railway target before running any bootstrap command.

### Step 2: Run a production dry-run through the web service

Run:

```bash
rtk env RAILWAY_CALLER=skill:use-railway@1.2.5 RAILWAY_AGENT_SESSION=railway-skill-sure-bootstrap railway run --service sure-web --environment production -- env DRY_RUN=1 bin/rails platform_bootstrap:multi_company_owners
```

Expected:

```text
Password for adminF0@bookeepz.net:
Password for adminF1@bookeepz.net:
Multi-company owner bootstrap validated in dry-run mode.
Families:
  - Risingstone infra pvt ltd
  - Risingstone ventures pvt ltd
  - Risingstone projects pvt Ltd
  - Mahetel pvt ltd
Users:
  - adminf0@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
  - adminf1@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
```

Prefer hidden interactive prompts. If `railway run` is non-interactive and cannot accept noecho prompts, set `ADMIN_F0_PASSWORD` and `ADMIN_F1_PASSWORD` in a one-shot shell outside the command transcript/history, run the command immediately, then clear those variables. Do not put bootstrap passwords in `.env`, `.env.local`, `railway.json`, tracked files, shell history, or Railway variables unless the intent is to store long-lived service secrets.

### Step 3: Execute the production bootstrap

Run:

```bash
rtk env RAILWAY_CALLER=skill:use-railway@1.2.5 RAILWAY_AGENT_SESSION=railway-skill-sure-bootstrap railway run --service sure-web --environment production -- bin/rails platform_bootstrap:multi_company_owners
```

Expected:

```text
Password for adminF0@bookeepz.net:
Password for adminF1@bookeepz.net:
Multi-company owner bootstrap completed.
Families:
  - Risingstone infra pvt ltd
  - Risingstone ventures pvt ltd
  - Risingstone projects pvt Ltd
  - Mahetel pvt ltd
Users:
  - adminf0@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
  - adminf1@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
```

Use the same password-handling rule as the dry-run: hidden prompt first; only use one-shot environment variables if the Railway execution path cannot prompt interactively, and clear them immediately afterward.

### Step 4: Verify production records without printing secrets

Run:

```bash
rtk env RAILWAY_CALLER=skill:use-railway@1.2.5 RAILWAY_AGENT_SESSION=railway-skill-sure-bootstrap railway run --service sure-web --environment production -- bin/rails runner 'emails = %w[adminf0@bookeepz.net adminf1@bookeepz.net]; rows = User.includes(:family).where(email: emails).order(:email).map { |user| { email: user.email, role: user.role, family_name: user.family&.name } }; puts({ families: Family.where(name: PlatformBootstrap::MultiCompanyOwners::COMPANY_NAMES).order(:name).pluck(:name), users: rows }.inspect)'
```

Expected:

```text
Families must include exactly these four company names:
- Risingstone infra pvt ltd
- Risingstone ventures pvt ltd
- Risingstone projects pvt Ltd
- Mahetel pvt ltd

Users must include exactly these two rows:
- email: adminf0@bookeepz.net, role: super_admin, family_name: Risingstone infra pvt ltd
- email: adminf1@bookeepz.net, role: super_admin, family_name: Risingstone infra pvt ltd
```

Do not print passwords, password digests, reset tokens, session tokens, or other secrets.

### Step 5: Final local verification

Run:

```bash
rtk git status --short --branch
```

Expected: only intended source changes plus any already-known untracked files such as `railway.json`.

Run:

```bash
rtk git log --oneline -n 12
```

Expected: recent history includes the multi-company bootstrap service, test, task, and runbook commits.

## Self-Review

- Spec coverage: The implementation creates four `Family` records, two `super_admin` users, uses `Risingstone infra pvt ltd` as both owners' primary family, avoids multi-company membership, keeps passwords out of files/output, and includes dry-run plus production verification.
- Secrets hygiene: The runbook never includes real passwords or password digests.
- Type consistency: The service is consistently named `PlatformBootstrap::MultiCompanyOwners`; the rake task calls that class; tests use the same constants and emails.
