# Multi-Company Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an idempotent bootstrap path that creates four company workspaces and two platform-wide super-admin users.

**Architecture:** Implement a small service object that owns all business logic for company/user creation, then expose it through a rake task that prompts for passwords without echoing them. Tests cover the service directly; the rake task stays thin and only handles operator input/output.

**Tech Stack:** Rails, ActiveRecord, Minitest, Rake, Ruby `io/console`.

---

## File Structure

- Create `app/services/platform_bootstrap/multi_company_owners.rb`
  - Owns the idempotent creation/update logic.
  - Knows the four company names, the two owner emails/labels, and default primary family.
  - Validates passwords before writing records.
  - Supports `dry_run: true` by rolling back writes after validation.
- Create `test/services/platform_bootstrap/multi_company_owners_test.rb`
  - Covers create, update/idempotency, dry-run rollback, and password validation.
- Create `lib/tasks/platform_bootstrap.rake`
  - Provides `platform_bootstrap:multi_company_owners`.
  - Reads passwords from `ADMIN_F0_PASSWORD` and `ADMIN_F1_PASSWORD`, or prompts with no echo on an interactive TTY.
  - Supports boolean `DRY_RUN` values such as `DRY_RUN=1` and `DRY_RUN=true`.
- Do not modify migrations, schema, auth controllers, or admin UI.

## Task 1: Add Service Tests

**Files:**
- Create: `test/services/platform_bootstrap/multi_company_owners_test.rb`

- [ ] **Step 1: Write the failing service test**

Create `test/services/platform_bootstrap/multi_company_owners_test.rb` with:

```ruby
require "test_helper"

module PlatformBootstrap
  class MultiCompanyOwnersTest < ActiveSupport::TestCase
    VALID_PASSWORD_F0 = ["Test", "F0", "Password", "!2026"].join
    VALID_PASSWORD_F1 = ["Test", "F1", "Password", "!2026"].join

    PASSWORDS = {
      "adminF0@bookeepz.net" => VALID_PASSWORD_F0,
      "adminF1@bookeepz.net" => VALID_PASSWORD_F1
    }.freeze

    COMPANY_NAMES = [
      "Risingstone infra pvt ltd",
      "Risingstone ventures pvt ltd",
      "Risingstone projects pvt Ltd",
      "Mahetel pvt ltd"
    ].freeze

    test "creates four company families and two super admin owners" do
      result = MultiCompanyOwners.new(passwords: PASSWORDS).call

      assert result.success?

      COMPANY_NAMES.each do |name|
        assert_equal 1, Family.where(name: name).count, "expected one family named #{name}"
      end

      admin_f0 = User.find_by!(email: "adminf0@bookeepz.net")
      admin_f1 = User.find_by!(email: "adminf1@bookeepz.net")
      primary_family = Family.find_by!(name: "Risingstone infra pvt ltd")

      assert_equal "super_admin", admin_f0.role
      assert_equal "super_admin", admin_f1.role
      assert_equal primary_family, admin_f0.family
      assert_equal primary_family, admin_f1.family
      assert_equal "F0-SU-1", admin_f0.first_name
      assert_equal "F0-SU-2", admin_f1.first_name
      assert admin_f0.authenticate(VALID_PASSWORD_F0)
      assert admin_f1.authenticate(VALID_PASSWORD_F1)
    end

    test "rerun updates existing records without duplicating families or users" do
      MultiCompanyOwners.new(passwords: PASSWORDS).call

      updated_passwords = {
        "adminF0@bookeepz.net" => ["Changed", "F0", "Password", "!2026"].join,
        "adminF1@bookeepz.net" => ["Changed", "F1", "Password", "!2026"].join
      }

      result = MultiCompanyOwners.new(passwords: updated_passwords).call

      assert result.success?
      assert_equal 1, User.where(email: "adminf0@bookeepz.net").count
      assert_equal 1, User.where(email: "adminf1@bookeepz.net").count

      COMPANY_NAMES.each do |name|
        assert_equal 1, Family.where(name: name).count, "expected no duplicate family named #{name}"
      end

      admin_f0 = User.find_by!(email: "adminf0@bookeepz.net")
      admin_f1 = User.find_by!(email: "adminf1@bookeepz.net")

      assert admin_f0.authenticate(updated_passwords.fetch("adminF0@bookeepz.net"))
      assert admin_f1.authenticate(updated_passwords.fetch("adminF1@bookeepz.net"))
      assert_equal "super_admin", admin_f0.role
      assert_equal "super_admin", admin_f1.role
    end

    test "dry run validates but rolls back changes" do
      result = MultiCompanyOwners.new(passwords: PASSWORDS, dry_run: true).call

      assert result.success?
      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
      assert_nil User.find_by(email: "adminf1@bookeepz.net")
    end

    test "rejects missing password for required owner" do
      error = assert_raises(ArgumentError) do
        MultiCompanyOwners.new(passwords: { "adminF0@bookeepz.net" => VALID_PASSWORD_F0 }).call
      end

      assert_includes error.message, "Missing password for adminF1@bookeepz.net"
    end

    test "rejects weak passwords before writing records" do
      weak_passwords = {
        "adminF0@bookeepz.net" => "weak",
        "adminF1@bookeepz.net" => VALID_PASSWORD_F1
      }

      error = assert_raises(ArgumentError) do
        MultiCompanyOwners.new(passwords: weak_passwords).call
      end

      assert_includes error.message, "Password for adminF0@bookeepz.net must be at least 8 characters"
      assert_equal 0, Family.where(name: COMPANY_NAMES).count
      assert_nil User.find_by(email: "adminf0@bookeepz.net")
    end
  end
end
```

- [ ] **Step 2: Run the service test to verify it fails**

Run:

```bash
rtk bin/rails test test/services/platform_bootstrap/multi_company_owners_test.rb
```

Expected: FAIL with `uninitialized constant PlatformBootstrap::MultiCompanyOwners`.

- [ ] **Step 3: Commit the failing test**

```bash
rtk git add test/services/platform_bootstrap/multi_company_owners_test.rb
rtk git commit -m "test: cover multi-company owner bootstrap"
```

## Task 2: Implement Bootstrap Service

**Files:**
- Create: `app/services/platform_bootstrap/multi_company_owners.rb`
- Test: `test/services/platform_bootstrap/multi_company_owners_test.rb`

- [ ] **Step 1: Write the service implementation**

Create `app/services/platform_bootstrap/multi_company_owners.rb` with:

```ruby
# frozen_string_literal: true

module PlatformBootstrap
  class MultiCompanyOwners
    COMPANY_NAMES = [
      "Risingstone infra pvt ltd",
      "Risingstone ventures pvt ltd",
      "Risingstone projects pvt Ltd",
      "Mahetel pvt ltd"
    ].freeze

    PRIMARY_FAMILY_NAME = "Risingstone infra pvt ltd"

    OWNERS = [
      { email: "adminF0@bookeepz.net", label: "F0-SU-1" },
      { email: "adminF1@bookeepz.net", label: "F0-SU-2" }
    ].freeze

    Result = Data.define(:families, :users, :dry_run) do
      def success?
        true
      end
    end

    def initialize(passwords:, dry_run: false)
      @passwords = passwords.to_h.transform_keys { |key| normalize_email(key) }
      @dry_run = dry_run
    end

    def call
      validate_passwords!

      families = nil
      users = nil

      ActiveRecord::Base.transaction do
        families = upsert_families
        users = upsert_users(primary_family: families.fetch(PRIMARY_FAMILY_NAME))

        raise ActiveRecord::Rollback if dry_run?
      end

      Result.new(families: families.values, users: users, dry_run: dry_run?)
    end

    private

      attr_reader :passwords, :dry_run

      def dry_run?
        dry_run == true
      end

      def upsert_families
        COMPANY_NAMES.index_with do |name|
          family = Family.find_or_initialize_by(name: name)
          family.currency = "USD" if family.currency.blank?
          family.locale = I18n.default_locale.to_s if family.locale.blank?
          family.save!
          family
        end
      end

      def upsert_users(primary_family:)
        OWNERS.map do |owner|
          email = normalize_email(owner.fetch(:email))
          user = User.find_or_initialize_by(email: email)

          user.assign_attributes(
            first_name: owner.fetch(:label),
            last_name: nil,
            family: primary_family,
            role: :super_admin,
            password: passwords.fetch(email),
            password_confirmation: passwords.fetch(email),
            onboarded_at: user.onboarded_at || Time.current,
            ui_layout: "dashboard",
            show_sidebar: true,
            show_ai_sidebar: true
          )

          user.save!
          user
        end
      end

      def validate_passwords!
        OWNERS.each do |owner|
          email = normalize_email(owner.fetch(:email))
          password = passwords[email]

          raise ArgumentError, "Missing password for #{owner.fetch(:email)}" if password.blank?

          password_errors(password).each do |message|
            raise ArgumentError, "Password for #{owner.fetch(:email)} #{message}"
          end
        end
      end

      def password_errors(password)
        errors = []
        errors << "must be at least 8 characters" if password.length < 8
        errors << "must include both uppercase and lowercase letters" unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
        errors << "must include at least one number" unless password.match?(/\d/)
        errors << "must include at least one special character" unless password.match?(/[!@#$%^&*(),.?":{}|<>]/)
        errors
      end

      def normalize_email(email)
        email.to_s.strip.downcase
      end
  end
end
```

- [ ] **Step 2: Run the service test**

Run:

```bash
rtk bin/rails test test/services/platform_bootstrap/multi_company_owners_test.rb
```

Expected: PASS.

- [ ] **Step 3: Run focused existing model tests**

Run:

```bash
rtk bin/rails test test/models/user_test.rb test/models/family_test.rb
```

Expected: PASS.

- [ ] **Step 4: Commit the service implementation**

```bash
rtk git add app/services/platform_bootstrap/multi_company_owners.rb test/services/platform_bootstrap/multi_company_owners_test.rb
rtk git commit -m "feat: add multi-company owner bootstrap service"
```

## Task 3: Add Operator Rake Task

**Files:**
- Create: `lib/tasks/platform_bootstrap.rake`

- [ ] **Step 1: Add the rake task**

Create `lib/tasks/platform_bootstrap.rake` with:

```ruby
# frozen_string_literal: true

require "io/console"

namespace :platform_bootstrap do
  desc "Create Risingstone/Mahetel company workspaces and platform owner super admins"
  task multi_company_owners: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])

    passwords = {
      "adminF0@bookeepz.net" => secret_value("ADMIN_F0_PASSWORD", "Password for adminF0@bookeepz.net"),
      "adminF1@bookeepz.net" => secret_value("ADMIN_F1_PASSWORD", "Password for adminF1@bookeepz.net")
    }

    result = PlatformBootstrap::MultiCompanyOwners.new(passwords: passwords, dry_run: dry_run).call

    puts "Multi-company owner bootstrap #{dry_run ? 'validated in dry-run mode' : 'completed'}."
    puts "Families:"
    result.families.each do |family|
      puts "  - #{family.name}"
    end

    puts "Users:"
    result.users.each do |user|
      puts "  - #{user.email}: #{user.role}, primary_family=#{user.family.name}"
    end
  end

  def secret_value(env_key, prompt)
    return ENV.fetch(env_key) if ENV[env_key].present?

    unless $stdin.tty?
      raise ArgumentError, "Set #{env_key} or run this task from an interactive TTY"
    end

    $stderr.print "#{prompt}: "
    value = $stdin.noecho(&:gets).to_s.chomp
    $stderr.puts
    raise ArgumentError, "#{env_key} cannot be blank" if value.blank?

    value
  end
end
```

- [ ] **Step 2: Run the rake task in dry-run mode**

Run from an interactive shell:

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

The password input should not echo in the terminal.

`DRY_RUN=true` is also accepted. Password values should be entered through the hidden interactive prompts, not written to `.env`, shell history, tracked files, or long-lived service variables for a one-time bootstrap.

- [ ] **Step 3: Verify dry-run did not write records**

Run:

```bash
rtk bin/rails runner 'puts({ families: Family.where(name: PlatformBootstrap::MultiCompanyOwners::COMPANY_NAMES).count, users: User.where(email: %w[adminf0@bookeepz.net adminf1@bookeepz.net]).count }.inspect)'
```

Expected:

```text
{:families=>0, :users=>0}
```

If local fixtures or prior manual data already contain these records, expected counts should reflect the pre-existing state exactly and must not increase after dry-run.

- [ ] **Step 4: Run the focused test suite again**

Run:

```bash
rtk bin/rails test test/services/platform_bootstrap/multi_company_owners_test.rb test/models/user_test.rb test/models/family_test.rb
```

Expected: PASS.

- [ ] **Step 5: Commit the rake task**

```bash
rtk git add lib/tasks/platform_bootstrap.rake
rtk git commit -m "feat: add multi-company owner bootstrap task"
```

## Task 4: Production Execution Runbook

**Files:**
- Modify: `docs/superpowers/plans/2026-06-10-multi-company-bootstrap.md`

- [ ] **Step 1: Confirm the Railway target**

Run:

```bash
rtk env RAILWAY_CALLER=skill:use-railway@1.2.5 RAILWAY_AGENT_SESSION=railway-skill-sure-bootstrap railway status --json
```

Confirm the JSON shows the intended target before continuing:

```text
project: sure
environment: production
service: sure-web
```

If the project, environment, or service differs, stop and switch to the correct Railway target before running any bootstrap command.

- [ ] **Step 2: Run a production dry-run through the web service**

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

`DRY_RUN=true` is also accepted. Prefer the hidden interactive prompts. If `railway run` is non-interactive and cannot accept noecho prompts, use a one-shot shell that sets `ADMIN_F0_PASSWORD` and `ADMIN_F1_PASSWORD` outside the command transcript/history, run the command immediately, then clear those variables. Do not put bootstrap passwords in `.env`, `.env.local`, `railway.json`, tracked files, shell history, or Railway variables unless the intent is to store long-lived service secrets.

- [ ] **Step 3: Execute the production bootstrap**

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

- [ ] **Step 4: Verify production records without printing secrets**

Run:

```bash
rtk env RAILWAY_CALLER=skill:use-railway@1.2.5 RAILWAY_AGENT_SESSION=railway-skill-sure-bootstrap railway run --service sure-web --environment production -- bin/rails runner 'puts({ families: Family.where(name: PlatformBootstrap::MultiCompanyOwners::COMPANY_NAMES).pluck(:name), users: User.where(email: %w[adminf0@bookeepz.net adminf1@bookeepz.net]).order(:email).pluck(:email, :role, :family_id) }.inspect)'
```

Expected:

```text
Families must include the four company names. Users must include two rows:

- `adminf0@bookeepz.net`, `super_admin`, and a non-empty family UUID
- `adminf1@bookeepz.net`, `super_admin`, and a non-empty family UUID
```

Do not print password digests.

- [ ] **Step 5: Final local verification**

Run:

```bash
rtk git status --short --branch
```

Expected: only intended source changes plus any already-known untracked files such as `railway.json`.

Run:

```bash
rtk git log --oneline -n 4
```

Expected: commits for the service test, service implementation, rake task, and any plan/spec commits.

## Self-Review

- Spec coverage: The plan creates four `Family` records, two `super_admin` users, uses `Risingstone infra pvt ltd` as primary family, avoids multi-company membership, keeps passwords out of files/output, and includes dry-run plus verification.
- Incomplete-marker scan: No incomplete markers or undefined code names remain in this plan.
- Type consistency: The service is consistently named `PlatformBootstrap::MultiCompanyOwners`; the rake task calls that class; tests use the same constants and emails.
