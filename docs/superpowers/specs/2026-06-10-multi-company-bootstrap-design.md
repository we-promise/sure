# Multi-Company Bootstrap Design

## Context

Sure currently uses `Family` as the tenant/workspace boundary. Users, accounts, transactions, imports, exports, budgets, goals, merchants, and dashboard data are scoped through `family_id`. The app does not currently have a separate `Organization` or `Company` model, and each `User` belongs to one `Family`.

The requested setup is for two platform owners to access and administer four company workspaces:

- Risingstone infra pvt ltd
- Risingstone ventures pvt ltd
- Risingstone projects pvt Ltd
- Mahetel pvt ltd

The selected access model is platform-wide `super_admin` for both users.

## Goals

- Create four separate financial workspaces, one per company.
- Create two platform owner users:
  - `adminF0@bookeepz.net`, labelled as `F0-SU-1`
  - `adminF1@bookeepz.net`, labelled as `F0-SU-2`
- Assign both users the existing `super_admin` role.
- Keep the setup aligned with the current app model instead of adding multi-company memberships now.
- Make the database bootstrap idempotent so it can be rerun without duplicating records.

## Non-Goals

- Do not add an `Organization` or `Company` model in this bootstrap.
- Do not add multi-family user membership or a company switcher.
- Do not add the entry-only accountant role in this bootstrap.
- Do not create email inboxes for `bookeepz.net`; mailbox creation belongs to the external email provider.
- Do not change DNS or Railway domains as part of this user/company bootstrap.

## Data Model

Each company will be represented by an existing `Family` record. This gives each company a separate tenant boundary and a separate dashboard because dashboard queries use `Current.family`.

Each platform owner will be represented by an existing `User` record:

- `email`: login identity
- `first_name` or `last_name`: stores the human label such as `F0-SU-1`
- `role`: `super_admin`
- `family_id`: one primary family, required by the current schema

Because `users.family_id` is required, each user must be assigned to one primary family even though the `super_admin` role is platform-wide. The primary family is only the user's default workspace, not the full scope of their authority. The bootstrap will use `Risingstone infra pvt ltd` as the default primary family for both users.

## Bootstrap Behavior

The bootstrap should run as an idempotent Rails task or runner script:

1. Look up or create the four `Family` records by exact name.
2. Look up or create `adminF0@bookeepz.net`.
3. Look up or create `adminF1@bookeepz.net`.
4. Assign both users to `Risingstone infra pvt ltd` as their primary family.
5. Set both users to `role: :super_admin`.
6. Set password values from operator-provided input or environment variables at execution time.
7. Print non-secret verification output showing user emails, roles, and family names.

The bootstrap must not print passwords or write them into repo files.

## Password Requirements

Passwords must satisfy the current registration requirements:

- At least 8 characters
- At least one uppercase letter
- At least one lowercase letter
- At least one number
- At least one special character

Passwords should be supplied only at execution time.

## Access Model

Both users are platform-wide `super_admin` users. This allows them to access the admin interface and manage users globally. It does not introduce a restricted "owner of only these four companies" model.

Company-specific dashboard access remains based on the app's existing family-scoped request context. If the owners need routine first-class switching between company dashboards without impersonation or admin workflows, that is a later feature requiring multi-family membership and a company switcher.

## Verification

After execution, verify:

- Exactly one `Family` record exists for each requested company name.
- `adminF0@bookeepz.net` exists and has `role == "super_admin"`.
- `adminF1@bookeepz.net` exists and has `role == "super_admin"`.
- Both users have a non-null `family_id`.
- No password values were printed or committed.

## Risks and Follow-Up

This bootstrap intentionally gives broad platform access. If future requirements require restricting owners to only selected companies, implement a proper company membership model rather than continuing to rely on global `super_admin`.

The entry-only accountant requirement is separate. No existing role currently supports add-only entries with no read access to financial data. That should be designed as a dedicated role or account permission in a separate implementation.
