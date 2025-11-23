# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Development Server
- `bin/dev` - Start development server (Rails, Sidekiq, Tailwind CSS watcher)
- `bin/rails server` - Start Rails server only
- `bin/rails console` - Open Rails console

### Testing
- `bin/rails test` - Run all tests
- `bin/rails test:db` - Run tests with database reset
- `bin/rails test:system` - Run system tests only (use sparingly - they take longer)
- `bin/rails test test/models/account_test.rb` - Run specific test file
- `bin/rails test test/models/account_test.rb:42` - Run specific test at line

### Linting & Formatting
- `bin/rubocop` - Run Ruby linter
- `npm run lint` - Check JavaScript/TypeScript code
- `npm run lint:fix` - Fix JavaScript/TypeScript issues
- `npm run format` - Format JavaScript/TypeScript code
- `bin/brakeman` - Run security analysis

### Database
- `bin/rails db:prepare` - Create and migrate database
- `bin/rails db:migrate` - Run pending migrations
- `bin/rails db:rollback` - Rollback last migration
- `bin/rails db:seed` - Load seed data

### Setup
- `bin/setup` - Initial project setup (installs dependencies, prepares database)

## Pre-Pull Request CI Workflow

ALWAYS run these commands before opening a pull request:

1. **Tests** (Required):
   - `bin/rails test` - Run all tests (always required)
   - `bin/rails test:system` - Run system tests (only when applicable, they take longer)

2. **Linting** (Required):
   - `bin/rubocop -f github -a` - Ruby linting with auto-correct
   - `bundle exec erb_lint ./app/**/*.erb -a` - ERB linting with auto-correct

3. **Security** (Required):
   - `bin/brakeman --no-pager` - Security analysis

Only proceed with pull request creation if ALL checks pass.

## General Development Rules

### Authentication Context
- Use `Current.user` for the current user. Do NOT use `current_user`.
- Use `Current.family` for the current family. Do NOT use `current_family`.

### Development Guidelines
- Carefully read project conventions and guidelines before generating any code.
- Do not run `rails server` in your responses
- Do not run `touch tmp/restart.txt`
- Do not run `rails credentials`
- Do not automatically run migrations

## High-Level Architecture

### Application Modes
The codebase runs in two distinct modes:
- **Managed**: A team operates and manages servers for users (Rails.application.config.app_mode = "managed")
- **Self Hosted**: Users host the codebase on their own infrastructure, typically through Docker Compose (Rails.application.config.app_mode = "self_hosted")

### Core Domain Model
The application is built around financial data management with these key relationships:
- **User** → has many **Accounts** → has many **Transactions**
- **Account** types: checking, savings, credit cards, investments, crypto, loans, properties
- **Transaction** → belongs to **Category**, can have **Tags** and **Rules**
- **Investment accounts** → have **Holdings** → track **Securities** via **Trades**

### API Architecture
The application provides both internal and external APIs:
- Internal API: Controllers serve JSON via Turbo for SPA-like interactions
- External API: `/api/v1/` namespace with Doorkeeper OAuth and API key authentication
- API responses use Jbuilder templates for JSON rendering
- Rate limiting via Rack Attack with configurable limits per API key

### Sync & Import System
Two primary data ingestion methods:
1. **Plaid Integration**: Real-time bank account syncing
   - `PlaidItem` manages connections
   - `Sync` tracks sync operations
   - Background jobs handle data updates
2. **CSV Import**: Manual data import with mapping
   - `Import` manages import sessions
   - Supports transaction and balance imports
   - Custom field mapping with transformation rules

### Background Processing
Sidekiq handles asynchronous tasks:
- Account syncing (`SyncJob`)
- Import processing (`ImportJob`)
- AI chat responses (`AssistantResponseJob`)
- Scheduled maintenance via sidekiq-cron

### Frontend Architecture
- **Hotwire Stack**: Turbo + Stimulus for reactive UI without heavy JavaScript
- **ViewComponents**: Reusable UI components in `app/components/`
- **Stimulus Controllers**: Handle interactivity, organized alongside components
- **Charts**: D3.js for financial visualizations (time series, donut, sankey)
- **Styling**: Tailwind CSS v4.x with custom design system
  - Design system defined in `app/assets/tailwind/maybe-design-system.css`
  - Always use functional tokens (e.g., `text-primary` not `text-white`)
  - Prefer semantic HTML elements over JS components
  - Use `icon` helper for icons, never `lucide_icon` directly
- **i18n**: All user-facing strings must use localization (i18n). Update locale files for each new or changed element.

### Internationalization (i18n) Guidelines
- **Key Organization**: Use hierarchical keys by feature: `accounts.index.title`, `transactions.form.amount_label`
- **Translation Helper**: Always use `t()` helper for user-facing strings
- **Interpolation**: Use for dynamic content: `t("users.greeting", name: user.name)`
- **Pluralization**: Use Rails pluralization: `t("transactions.count", count: @transactions.count)`
- **Locale Files**: Update `config/locales/en.yml` for new strings
- **Missing Translations**: Configure to raise errors in development for missing keys

### Community Localization
We welcome community-contributed translations! When adding or updating localizations:

- **Adding New Languages**:
  1. Create locale files in `config/locales/[language_code]/` (e.g., `config/locales/fr/`)
  2. Follow the same hierarchical structure as English locale files
  3. **CRITICAL**: Add the language code to `SUPPORTED_LOCALES` in `app/helpers/languages_helper.rb` to make it available in the UI
  4. Ensure the language is also present in `LANGUAGE_MAPPING` in the same file
  5. Test the language thoroughly in the UI before submitting

- **Translation Quality Standards**:
  - Maintain consistent terminology across all files
  - Preserve interpolation variables exactly as they appear (e.g., `%{name}`, `%{count}`)
  - Respect pluralization rules for your language
  - Keep formatting characters and HTML tags intact
  - Test all translations in context, not just isolated strings

- **File Organization**:
  - Mirror the English locale structure exactly
  - One feature per file (e.g., `accounts.yml`, `transactions.yml`)
  - Use the same nesting depth as the English version
  - Include all translation keys, even if some values are identical to English

- **Testing Translations**:
  - Switch your user account to the new language in settings
  - Navigate through all major features to verify translations
  - Check for missing keys (will show as translation path in development)
  - Verify number, date, and currency formatting is appropriate for the locale

- **Supported vs Community Locales**:
  - Languages in `SUPPORTED_LOCALES` have extensive (50+ files) translations
  - Community locales may have partial coverage but are still valuable
  - When adding a new locale, aim for complete coverage of core features first
  - Document any incomplete sections in your pull request

### Multi-Currency Support
- All monetary values stored in base currency (user's primary currency)
- `Money` objects handle currency conversion and formatting
- Historical exchange rates for accurate reporting

### Security & Authentication
- Session-based auth for web users
- API authentication via:
  - OAuth2 (Doorkeeper) for third-party apps
  - API keys with JWT tokens for direct API access
- Scoped permissions system for API access
- Strong parameters and CSRF protection throughout

### Testing Philosophy
- Comprehensive test coverage using Rails' built-in Minitest
- Fixtures for test data (avoid FactoryBot)
- Keep fixtures minimal (2-3 per model for base cases)
- VCR for external API testing
- System tests for critical user flows (use sparingly)
- Test helpers in `test/support/` for common scenarios
- Only test critical code paths that significantly increase confidence
- Write tests as you go, when required

### Performance Considerations
- Database queries optimized with proper indexes
- N+1 queries prevented via includes/joins
- Background jobs for heavy operations
- Caching strategies for expensive calculations
- Turbo Frames for partial page updates

### Development Workflow
- Feature branches merged to `main`
- Docker support for consistent environments
- Environment variables via `.env` files
- Lookbook for component development (`/lookbook`)
- Letter Opener for email preview in development

## Project Conventions

### Convention 1: Minimize Dependencies
- Push Rails to its limits before adding new dependencies
- Strong technical/business reason required for new dependencies
- Favor old and reliable over new and flashy

### Convention 2: Skinny Controllers, Fat Models
- Business logic in `app/models/` folder, avoid `app/services/`
- Use Rails concerns and POROs for organization
- Models should answer questions about themselves: `account.balance_series` not `AccountSeries.new(account).call`

### Convention 3: Hotwire-First Frontend
- **Native HTML preferred over JS components**
  - Use `<dialog>` for modals, `<details><summary>` for disclosures
- **Leverage Turbo frames** for page sections over client-side solutions
- **Query params for state** over localStorage/sessions
- **Server-side formatting** for currencies, numbers, dates
- **Always use `icon` helper** in `application_helper.rb`, NEVER `lucide_icon` directly

### Convention 4: Optimize for Simplicity
- Prioritize good OOP domain design over performance
- Focus performance only on critical/global areas (avoid N+1 queries, mindful of global layouts)

### Convention 5: Database vs ActiveRecord Validations
- Simple validations (null checks, unique indexes) in DB
- ActiveRecord validations for convenience in forms (prefer client-side when possible)
- Complex validations and business logic in ActiveRecord

## TailwindCSS Design System

### Design System Rules
- **Always reference `app/assets/tailwind/maybe-design-system.css`** for primitives and tokens
- **Use functional tokens** defined in design system:
  - `text-primary` instead of `text-white`
  - `bg-container` instead of `bg-white`
  - `border border-primary` instead of `border border-gray-200`
- **NEVER create new styles** in design system files without permission
- **Always generate semantic HTML**

## Component Architecture

### ViewComponent vs Partials Decision Making

**Use ViewComponents when:**
- Element has complex logic or styling patterns
- Element will be reused across multiple views/contexts
- Element needs structured styling with variants/sizes
- Element requires interactive behavior or Stimulus controllers
- Element has configurable slots or complex APIs
- Element needs accessibility features or ARIA support

**Use Partials when:**
- Element is primarily static HTML with minimal logic
- Element is used in only one or few specific contexts
- Element is simple template content
- Element doesn't need variants, sizes, or complex configuration
- Element is more about content organization than reusable functionality

**Component Guidelines:**
- Prefer components over partials when available
- Keep domain logic OUT of view templates
- Logic belongs in component files, not template files

### Stimulus Controller Guidelines

**Declarative Actions (Required):**
```erb
<!-- GOOD: Declarative - HTML declares what happens -->
<div data-controller="toggle">
  <button data-action="click->toggle#toggle" data-toggle-target="button">
    <%= t("components.transaction_details.show_details") %>
  </button>
  <div data-toggle-target="content" class="hidden">
    <p><%= t("components.transaction_details.amount_label") %>: <%= @transaction.amount %></p>
    <p><%= t("components.transaction_details.date_label") %>: <%= @transaction.date %></p>
    <p><%= t("components.transaction_details.category_label") %>: <%= @transaction.category.name %></p>
  </div>
</div>
```

**Example locale file structure (config/locales/en.yml):**
```yaml
en:
  components:
    transaction_details:
      show_details: "Show Details"
      hide_details: "Hide Details"
      amount_label: "Amount"
      date_label: "Date"
      category_label: "Category"
```

**i18n Best Practices:**
- Organize keys by feature/component: `components.transaction_details.show_details`
- Use descriptive key names that indicate purpose: `show_details` not `button`
- Group related translations together in the same namespace
- Use interpolation for dynamic content: `t("users.welcome", name: user.name)`
- Always update locale files when adding new user-facing strings

**Controller Best Practices:**
- Keep controllers lightweight and simple (< 7 targets)
- Use private methods and expose clear public API
- Single responsibility or highly related responsibilities
- Component controllers stay in component directory, global controllers in `app/javascript/controllers/`
- Pass data via `data-*-value` attributes, not inline JavaScript

## Testing Philosophy

### General Testing Rules
- **ALWAYS use Minitest + fixtures** (NEVER RSpec or factories)
- Keep fixtures minimal (2-3 per model for base cases)
- Create edge cases on-the-fly within test context
- Use Rails helpers for large fixture creation needs

### Test Quality Guidelines
- **Write minimal, effective tests** - system tests sparingly
- **Only test critical and important code paths**
- **Test boundaries correctly:**
  - Commands: test they were called with correct params
  - Queries: test output
  - Don't test implementation details of other classes

### Testing Examples

```ruby
# GOOD - Testing critical domain business logic
test "syncs balances" do
  Holding::Syncer.any_instance.expects(:sync_holdings).returns([]).once
  assert_difference "@account.balances.count", 2 do
    Balance::Syncer.new(@account, strategy: :forward).sync_balances
  end
end

# BAD - Testing ActiveRecord functionality
test "saves balance" do 
  balance_record = Balance.new(balance: 100, currency: "USD")
  assert balance_record.save
end
```

### Stubs and Mocks
- Use `mocha` gem
- Prefer `OpenStruct` for mock instances
- Only mock what's necessary