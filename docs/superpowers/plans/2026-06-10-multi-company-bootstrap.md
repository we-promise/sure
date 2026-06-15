# Multi-Company Bootstrap Runbook

**Goal:** Create the four Risingstone/Mahetel family workspaces, the two platform-wide super-admin users, and the four family-scoped admin users that back the super-admin workspace picker.

The app remains single-family-per-user. F0/F1 workspace switching is implemented as a narrow impersonation shortcut, not as true multi-family membership.

## Authoritative Files

- `app/services/platform_bootstrap/multi_company_owners.rb`
- `lib/tasks/platform_bootstrap.rake`
- `app/models/impersonation_session.rb`
- `app/controllers/impersonation_sessions_controller.rb`
- `app/views/impersonation_sessions/_super_admin_bar.html.erb`
- `test/services/platform_bootstrap/multi_company_owners_test.rb`
- `test/models/impersonation_session_test.rb`
- `test/controllers/impersonation_sessions_controller_test.rb`
- `test/controllers/pages_controller_test.rb`

## Bootstrap Accounts

### Super admins

- `adminF0@bookeepz.net` -> label `F0-SU-1`, role `super_admin`, primary family `Risingstone infra pvt ltd`
- `adminF1@bookeepz.net` -> label `F0-SU-2`, role `super_admin`, primary family `Risingstone infra pvt ltd`

### Family admins

- `admin+rsinfra@bookeepz.net` -> label `RS-INFRA-ADMIN`, role `admin`, family `Risingstone infra pvt ltd`
- `admin+rsventures@bookeepz.net` -> label `RS-VENTURES-ADMIN`, role `admin`, family `Risingstone ventures pvt ltd`
- `admin+rsprojects@bookeepz.net` -> label `RS-PROJECTS-ADMIN`, role `admin`, family `Risingstone projects pvt Ltd`
- `admin+mahetel@bookeepz.net` -> label `MAHETEL-ADMIN`, role `admin`, family `Mahetel pvt ltd`

## One-Shot Password Inputs

Provide passwords through hidden prompts or one-shot environment variables only:

- `ADMIN_F0_PASSWORD`
- `ADMIN_F1_PASSWORD`
- `ADMIN_RSINFRA_PASSWORD`
- `ADMIN_RSVENTURES_PASSWORD`
- `ADMIN_RSPROJECTS_PASSWORD`
- `ADMIN_MAHETEL_PASSWORD`

Do not put these values in `.env`, `.env.local`, tracked files, shell history, or long-lived Railway service variables for a one-time bootstrap.

## Local Verification

Run the focused tests:

```bash
bin/rails test \
  test/services/platform_bootstrap/multi_company_owners_test.rb \
  test/models/impersonation_session_test.rb \
  test/controllers/impersonation_sessions_controller_test.rb \
  test/controllers/pages_controller_test.rb
```

Run a local dry-run:

```bash
env DRY_RUN=1 bin/rails platform_bootstrap:multi_company_owners
```

Expected output shape:

```text
Multi-company owner bootstrap validated in dry-run mode.
Families:
  - Risingstone infra pvt ltd
  - Risingstone ventures pvt ltd
  - Risingstone projects pvt Ltd
  - Mahetel pvt ltd
Users:
  - adminf0@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
  - adminf1@bookeepz.net: super_admin, primary_family=Risingstone infra pvt ltd
  - admin+rsinfra@bookeepz.net: admin, primary_family=Risingstone infra pvt ltd
  - admin+rsventures@bookeepz.net: admin, primary_family=Risingstone ventures pvt ltd
  - admin+rsprojects@bookeepz.net: admin, primary_family=Risingstone projects pvt Ltd
  - admin+mahetel@bookeepz.net: admin, primary_family=Mahetel pvt ltd
```

Dry-run must perform no writes.

## Rerun Expectations

Bootstrap reruns are intentionally narrow:

- existing families are found by name and left as-is
- India defaults (`INR`, `IN`, `%d-%m-%Y`) are applied only when bootstrap creates a family for the first time
- the starter `Expenditure` account is created only if the family has no depository account yet
- the six bootstrap users have role, family, password, and missing onboarding timestamp reasserted on each rerun
- existing non-security profile/sidebar preferences on persisted bootstrap users are preserved

This means rerunning bootstrap does **not** backfill blank or non-India locale/currency/date settings onto already-existing families.

## Production Execution

### Step 1: Confirm the Railway target

```bash
railway status --json
```

Confirm the selected target is the intended production project, environment, and `sure-web` service before mutation.

### Step 2: Production dry-run

```bash
railway run --service sure-web --environment production -- env DRY_RUN=1 bin/rails platform_bootstrap:multi_company_owners
```

If `railway run` cannot support hidden prompts, export the six password env vars in a one-shot shell, run the command immediately, then clear them.

### Step 3: Execute the production bootstrap

```bash
railway run --service sure-web --environment production -- bin/rails platform_bootstrap:multi_company_owners
```

### Step 4: Verify records without printing secrets

```bash
railway run --service sure-web --environment production -- bin/rails runner '
emails = %w[
  adminf0@bookeepz.net
  adminf1@bookeepz.net
  admin+rsinfra@bookeepz.net
  admin+rsventures@bookeepz.net
  admin+rsprojects@bookeepz.net
  admin+mahetel@bookeepz.net
]
rows = User.includes(:family).where(email: emails).order(:email).map { |user|
  { email: user.email, role: user.role, family_name: user.family&.name }
}
puts({ families: Family.where(name: PlatformBootstrap::MultiCompanyOwners::COMPANY_NAMES).order(:name).pluck(:name), users: rows }.inspect)
'
```

Confirm:

- exactly four families exist with the expected names
- F0/F1 are `super_admin`
- the four family admins are `admin`
- each family admin is attached to the expected family

If a family-admin user has drifted to the wrong family or role, the workspace picker and auto-approved impersonation path fail closed until the bootstrap user is corrected.

## Operator Flow

After bootstrap:

1. Sign in as `adminF0@bookeepz.net` or `adminF1@bookeepz.net`.
2. Enable the super-admin bar.
3. Choose a company from the workspace picker.
4. The app starts an auto-approved impersonation session into the matching family admin.
5. Work inside that family-scoped workspace.
6. Use `Leave` or `Terminate` to return to the base super-admin context.

The existing raw UUID impersonation field remains available for general support impersonation flows. Only the F0/F1 -> bootstrap family-admin path is auto-approved.

## Related UI Notes

- New families created through normal signup default to:
  - currency `INR`
  - country `IN`
  - date format `%d-%m-%Y`
- Admin-only `Tax`, `Imports`, and `Exports` now live in the primary application navigation and render in the main app shell instead of the Settings shell.
