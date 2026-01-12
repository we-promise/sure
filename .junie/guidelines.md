# Sure Project — Junie Guidelines (Persistent Context)

This single file provides optional, persistent context for JetBrains Junie/RubyMine users. It is a direct, verbatim port of the project’s `.cursor/rules/*.mdc` guidelines into one document, with only path normalization for links and cross-references updated to point to sections below. It does not alter or interfere with Cursor/Codex workflows.

Self-hosted emphasis: the Sure project primarily operates in self-hosted mode; if references to managed mode exist in the original text below, they are preserved as-is for accuracy.

---


## Original File: .cursor/rules/general-rules.mdc

```markdown
---
description: Miscellaneous rules to get the AI to behave
globs: *
alwaysApply: true
---
# General rules for AI 

- Use `Current.user` for the current user. Do NOT use `current_user`.
- Use `Current.family` for the current family. Do NOT use `current_family`.
- Prior to generating any code, carefully read the project conventions and guidelines
  - Read [project-design.mdc](#original-file-cursorrulesproject-designmdc) to understand the codebase
  - Read [project-conventions.mdc](#original-file-cursorrulesproject-conventionsmdc) to understand _how_ to write code for the codebase
  - Read [ui-ux-design-guidelines.mdc](#original-file-cursorrulesui-ux-design-guidelinesmdc) to understand how to implement frontend code specifically
- ActiveRecord migrations must inherit from `ActiveRecord::Migration[7.2]`. Do **not** use version 8.0 yet.

## Prohibited actions

- Do not run `rails server` in your responses.
- Do not run `touch tmp/restart.txt`
- Do not run `rails credentials`
- Do not automatically run migrations
```


---

## Original File: .cursor/rules/project-design.mdc

```markdown
---
description: This rule explains the system architecture and data flow of the Rails app
globs: *
alwaysApply: true
---

This file outlines how the codebase is structured and how data flows through the app.

This is a personal finance application built in Ruby on Rails.  The primary domain entities for this app are outlined below.  For an authoritative overview of the relationships, [schema.rb](db/schema.rb) is the source of truth.

## App Modes

The codebase runs in two distinct "modes", dictated by `Rails.application.config.app_mode`, which can be `managed` or `self_hosted`.

- "Managed" - in managed mode, a team operates and manages servers for users
- "Self Hosted" - in self hosted mode, users host the codebase on their own infrastructure, typically through Docker Compose.  We have an example [docker-compose.example.yml](docker-compose.example.yml) file that runs [Dockerfile](Dockerfile) for this mode.

## Families and Users

- `Family` - all Stripe subscriptions, financial accounts, and the majority of preferences are stored at the [family.rb](app/models/family.rb) level.
- `User` - all [session.rb](app/models/session.rb) happen at the [user.rb](app/models/user.rb) level.  A user belongs to a `Family` and can either be an `admin` or a `member`.  Typically, a `Family` has a single admin, or "head of household" that manages finances while there will be several `member` users who can see the family's finances from varying perspectives.

## Currency Preference

Each `Family` selects a currency preference.  This becomes the "main" currency in which all records are "normalized" to via [exchange_rate.rb](app/models/exchange_rate.rb) records so that the app can calculate metrics, historical graphs, and other insights in a single family currency.

## Accounts

The center of the app's domain is the [account.rb](app/models/account.rb).  This represents a single financial account that has a `balance` and `currency`.  For example, an `Account` could be "Chase Checking", which is a single financial account at Chase Bank.  A user could have multiple accounts at a single institution (i.e. "Chase Checking", "Chase Credit Card", "Chase Savings") or an account could be a standalone account, such as "My Home" (a primary residence).

### Accountables

In the app, [account.rb](app/models/account.rb) is a Rails "delegated type" with the following subtypes (separate DB tables).  Each account has a `classification` or either `asset` or `liability`.  While the types are a flat hierarchy, below, they have been organized by their classification:

- Asset accountables
  - [depository.rb](app/models/depository.rb) - a typical "bank account" such as a savings or checking account
  - [investment.rb](app/models/investment.rb) - an account that has "holdings" such as a brokerage, 401k, etc.
  - [crypto.rb](app/models/crypto.rb) - an account that tracks the value of one or more crypto holdings
  - [property.rb](app/models/property.rb) - an account that tracks the value of a physical property such as a house or rental property
  - [vehicle.rb](app/models/vehicle.rb) - an account that tracks the value of a vehicle
  - [other_asset.rb](app/models/other_asset.rb) - an asset that cannot be classified by the other account types.  For example, "jewelry".
- Liability accountables
  - [credit_card.rb](app/models/credit_card.rb) - an account that tracks the debt owed on a credit card
  - [loan.rb](app/models/loan.rb) - an account that tracks the debt owed on a loan (i.e. mortgage, student loan)
  - [other_liability.rb](app/models/other_liability.rb) - a liability that cannot be classified by the other account types.  For example, "IOU to a friend"

### Account Balances

An account [balance.rb](app/models/account/balance.rb) represents a single balance value for an account on a specific `date`.  A series of balance records is generated daily for each account and is how we show a user's historical balance graph.  

- For simple accounts like a "Checking Account", the balance represents the amount of cash in the account for a date.  
- For a more complex account like "Investment Brokerage", the `balance` represents the combination of the "cash balance" + "holdings value".  Each accountable type has different components that make up the "balance", but in all cases, the "balance" represents "How much the account is worth" (when `classification` is `asset`) or "How much is owed on the account" (when `classification` is `liability`)

All balances are calculated daily by [balance_calculator.rb](app/models/account/balance_calculator.rb).

### Account Holdings

An account [holding.rb](app/models/holding.rb) applies to [investment.rb](app/models/investment.rb) type accounts and represents a `qty` of a certain [security.rb](app/models/security.rb) at a specific `price` on a specific `date`.

For investment accounts with holdings, [base_calculator.rb](app/models/holding/base_calculator.rb) is used to calculate the daily historical holding quantities and prices, which are then rolled up into a final "Balance" for the account in [base_calculator.rb](app/models/account/balance/base_calculator.rb).

### Account Entries

An account [entry.rb](app/models/entry.rb) is also a Rails "delegated type".  `Entry` represents any record that _modifies_ an `Account` [balance.rb](app/models/account/balance.rb) and/or [holding.rb](app/models/holding.rb).  Therefore, every entry must have a `date`, `amount`, and `currency`.

The `amount` of an [entry.rb](app/models/entry.rb) is a signed value.  A _negative_ amount is an "inflow" of money to that account.  A _positive_ value is an "outflow" of money from that account.  For example:

- A negative amount for a credit card account represents a "payment" to that account, which _reduces_ its balance (since it is a `liability`)
- A negative amount for a checking account represents an "income" to that account, which _increases_ its balance (since it is an `asset`)
- A negative amount for an investment/brokerage trade represents a "sell" transaction, which _increases_ the cash balance of the account 

There are 3 entry types, defined as [entryable.rb](app/models/entryable.rb) records: 

- `Valuation` - an account [valuation.rb](app/models/valuation.rb) is an entry that says, "here is the value of this account on this date".  It is an absolute measure of an account value / debt.  If there is an `Valuation` of 5,000 for today's date, that means that the account balance will be 5,000 today.
- `Transaction` - an account [transaction.rb](app/models/transaction.rb) is an entry that alters the account balance by the `amount`.  This is the most common type of entry and can be thought of as an "income" or "expense".  
- `Trade` - an account [trade.rb](app/models/trade.rb) is an entry that only applies to an investment account.  This represents a "buy" or "sell" of a holding and has a `qty` and `price`.

### Account Transfers

A [transfer.rb](app/models/transfer.rb) represents a movement of money between two accounts.  A transfer has an inflow [transaction.rb](app/models/transaction.rb) and an outflow [transaction.rb](app/models/transaction.rb).  The codebase auto-matches transfers based on the following criteria:

- Must be from different accounts
- Must be within 4 days of each other
- Must be the same currency
- Must be opposite values

There are two primary forms of a transfer:

- Regular transfer - a normal movement of money between two accounts.  For example, "Transfer $500 from Checking account to Brokerage account". 
- Debt payment - a special form of transfer where the _receiver_ of funds is a [loan.rb](app/models/loan.rb) type account.  

Regular transfers are typically _excluded_ from income and expense calculations while a debt payment is considered an "expense".

## Plaid Items

A [plaid_item.rb](app/models/plaid_item.rb) represents a "connection" maintained by our external data provider, Plaid in the "hosted" mode of the app.  An "Item" has 1 or more [plaid_account.rb](app/models/plaid_account.rb) records, which are each associated 1:1 with an internal app [account.rb](app/models/account.rb).

All relevant metadata about the item and its underlying accounts are stored on [plaid_item.rb](app/models/plaid_item.rb) and [plaid_account.rb](app/models/plaid_account.rb), while the "normalized" data is then stored on internal app domain models.

## "Syncs"

The codebase has the concept of a [syncable.rb](app/models/concerns/syncable.rb), which represents any model which can have its data "synced" in the background.  "Syncables" include:

- `Account` - an account "sync" will sync account holdings, balances, and enhance transaction metadata
- `PlaidItem` - a Plaid Item "sync" fetches data from Plaid APIs, normalizes that data, stores it on internal app models, and then finally performs an "Account sync" for each of the underlying accounts created from the Plaid Item.
- `Family` - a Family "sync" loops through the family's Plaid Items and individual Accounts and "syncs" each of them.  A family is synced once per day, automatically through [auto_sync.rb](app/controllers/concerns/auto_sync.rb).

Each "sync" creates a [sync.rb](app/models/sync.rb) record in the database, which keeps track of the status of the sync, any errors that it encounters, and acts as an "audit table" for synced data.

Below are brief descriptions of each type of sync in more detail.

### Account Syncs

The most important type of sync is the account sync.  It is orchestrated by the account's `sync_data` method, which performs a few important tasks:

- Auto-matches transfer records for the account
- Calculates daily [balance.rb](app/models/account/balance.rb) records for the account from `account.start_date` to `Date.current` using [base_calculator.rb](app/models/account/balance/base_calculator.rb)
  - Balances are dependent on the calculation of [holding.rb](app/models/holding.rb), which uses [base_calculator.rb](app/models/account/holding/base_calculator.rb) 
- Enriches transaction data if enabled by user

An account sync happens every time an [entry.rb](app/models/entry.rb) is updated.

### Plaid Item Syncs

A Plaid Item sync is an ETL (extract, transform, load) operation:

1. [plaid_item.rb](app/models/plaid_item.rb) fetches data from the external Plaid API
2. [plaid_item.rb](app/models/plaid_item.rb) creates and loads this data to [plaid_account.rb](app/models/plaid_account.rb) records
3. [plaid_item.rb](app/models/plaid_item.rb) and [plaid_account.rb](app/models/plaid_account.rb) transform and load data to [account.rb](app/models/account.rb) and [entry.rb](app/models/entry.rb), the internal codebase representations of the data.

### Family Syncs

A family sync happens once daily via [auto_sync.rb](app/controllers/concerns/auto_sync.rb).  A family sync is an "orchestrator" of Account and Plaid Item syncs.

## Data Providers

The codebase utilizes several 3rd party data services to calculate historical account balances, enrich data, and more.  Since the app can be run in both "hosted" and "self hosted" mode, this means that data providers are _optional_ for self hosted users and must be configured.

Because of this optionality, data providers must be configured at _runtime_ through [registry.rb](app/models/provider/registry.rb) utilizing [setting.rb](app/models/setting.rb) for runtime parameters like API keys:

There are two types of 3rd party data in the codebase:

1. "Concept" data
2. One-off data

### "Concept" data

Since the app is self hostable, users may prefer using different providers for generic data like exchange rates and security prices.  When data is generic enough where we can easily swap out different providers, we call it a data "concept".

Each "concept" has an interface defined in the `app/models/provider/concepts` directory.

```plain
app/models/
  exchange_rate/
    provided.rb # <- Responsible for selecting the concept provider from the registry
  provider.rb # <- Base provider class
  provider/
    registry.rb <- Defines available providers by concept
    concepts/
      exchange_rate.rb <- defines the interface required for the exchange rate concept
```

### One-off data

For data that does not fit neatly into a "concept", an interface is not required and the concrete provider may implement ad-hoc methods called directly in code.

## "Provided" Concerns

In general, domain models should not be calling [registry.rb](app/models/provider/registry.rb) directly.  When 3rd party data is required for a domain model, we use the `Provided` concern within that model's namespace.  This concern is primarily responsible for:

- Choosing the provider to use for this "concept"
- Providing convenience methods on the model for accessing data

For example, [exchange_rate.rb](app/models/exchange_rate.rb) has a [provided.rb](app/models/exchange_rate/provided.rb) concern with the following convenience methods:

```rb
module ExchangeRate::Provided
  extend ActiveSupport::Concern

  class_methods do
    def provider
      registry = Provider::Registry.for_concept(:exchange_rates)
      registry.get_provider(:synth)
    end

    def find_or_fetch_rate(from:, to:, date: Date.current, cache: true)
      # Implementation 
    end

    def sync_provider_rates(from:, to:, start_date:, end_date: Date.current)
      # Implementation 
    end
  end
end
```

This exposes a generic access pattern where the caller does not care _which_ provider has been chosen for the concept of exchange rates and can get a predictable response:

```rb
def access_patterns_example
  # Call exchange rate provider directly
  ExchangeRate.provider.fetch_exchange_rate(from: "USD", to: "CAD", date: Date.current)

  # Call convenience method
  ExchangeRate.sync_provider_rates(from: "USD", to: "CAD", start_date: 2.days.ago.to_date)
end
```

## Concrete provider implementations

Each 3rd party data provider should have a class under the `Provider::` namespace that inherits from `Provider` and returns `with_provider_response`, which will return a `Provider::ProviderResponse` object:

```rb
class ConcreteProvider < Provider
  def fetch_some_data
    with_provider_response do
      ExampleData.new(
        example: "data"
      )
    end
  end
end
```

The `with_provider_response` automatically catches provider errors, so concrete provider classes should raise when valid data is not possible:

```rb
class ConcreteProvider < Provider
  def fetch_some_data
    with_provider_response do
      data = nil

      # Raise an error if data cannot be returned
      raise ProviderError.new("Could not find the data you need") if data.nil?

      data
    end
  end
end
```
```

---

## Original File: .cursor/rules/project-conventions.mdc

```markdown
---
description: 
globs: 
alwaysApply: true
---
This rule serves as high-level documentation for how you should write code in this codebase. 

## Project Tech Stack

- Web framework: Ruby on Rails
  - Minitest + fixtures for testing
  - Propshaft for asset pipeline
  - Hotwire Turbo/Stimulus for SPA-like UI/UX
  - TailwindCSS for styles
  - Lucide Icons for icons
  - OpenAI for AI chat
- Database: PostgreSQL
- Jobs: Sidekiq + Redis
- External
  - Payments: Stripe
  - User bank data syncing: Plaid

## Project conventions

These conventions should be used when writing code for the project.

### Convention 1: Minimize dependencies, vanilla Rails is plenty

Dependencies are a natural part of building software, but we aim to minimize them when possible to keep this open-source codebase easy to understand, maintain, and contribute to.

- Push Rails to its limits before adding new dependencies
- When a new dependency is added, there must be a strong technical or business reason to add it
- When adding dependencies, you should favor old and reliable over new and flashy 

### Convention 2: Leverage POROs and concerns over "service objects"

This codebase adopts a "skinny controller, fat models" convention.  Furthermore, we put almost _everything_ directly in the `app/models/` folder and avoid separate folders for business logic such as `app/services/`.

- Organize large pieces of business logic into Rails concerns and POROs (Plain ole' Ruby Objects)
- While a Rails concern _may_ offer shared functionality (i.e. "duck types"), it can also be a "one-off" concern that is only included in one place for better organization and readability.
- When concerns are used for code organization, they should be organized around the "traits" of a model; not for simply moving code to another spot in the codebase.
- When possible, models should answer questions about themselves—for example, we might have a method, `account.balance_series` that returns a time-series of the account's most recent balances.  We prefer this over something more service-like such as `AccountSeries.new(account).call`.

### Convention 3: Leverage Hotwire, write semantic HTML, CSS, and JS, prefer server-side solutions

- Native HTML is always preferred over JS-based components
  - Example 1: Use `<dialog>` element for modals instead of creating a custom component
  - Example 2: Use `<details><summary>...</summary></details>` for disclosures rather than custom components
- Leverage Turbo frames to break up the page over JS-driven client-side solutions
  - Example 1: A good example of turbo frame usage is in [application.html.erb](app/views/layouts/application.html.erb) where we load [chats_controller.rb](app/controllers/chats_controller.rb) actions in a turbo frame in the global layout
- Leverage query params in the URL for state over local storage and sessions.  If absolutely necessary, utilize the DB for persistent state.
- Use Turbo streams to enhance functionality, but do not solely depend on it
- Format currencies, numbers, dates, and other values server-side, then pass to Stimulus controllers for display only
- Keep client-side code for where it truly shines.  For example, @bulk_select_controller.js is a case where server-side solutions would degrade the user experience significantly.  When bulk-selecting entries, client-side solutions are the way to go and Stimulus provides the right toolset to achieve this.
- Always use the `icon` helper in [application_helper.rb](app/helpers/application_helper.rb) for icons.  NEVER use `lucide_icon` helper directly.

The Hotwire suite (Turbo/Stimulus) works very well with these native elements and we optimize for this.

### Convention 4: Optimize for simplicitly and clarity

All code should maximize readability and simplicity.

- Prioritize good OOP domain design over performance
- Only focus on performance for critical and global areas of the codebase; otherwise, don't sweat the small stuff.
  - Example 1: be mindful of loading large data payloads in global layouts
  - Example 2: Avoid N+1 queries

### Convention 5: Use ActiveRecord for complex validations, DB for simple ones, keep business logic out of DB

- Enforce `null` checks, unique indexes, and other simple validations in the DB
- ActiveRecord validations _may_ mirror the DB level ones, but not 100% necessary.  These are for convenience when error handling in forms.  Always prefer client-side form validation when possible.
- Complex validations and business logic should remain in ActiveRecord
```

---

## Original File: .cursor/rules/testing.mdc

```markdown
---
description: 
globs: test/**
alwaysApply: false
---
Use this rule to learn how to write tests for the codebase.

Due to the open-source nature of this project, we have chosen Minitest + Fixtures for testing to maximize familiarity and predictability.

- **General testing rules**
  - Always use Minitest and fixtures for testing, NEVER rspec or factories
  - Keep fixtures to a minimum.  Most models should have 2-3 fixtures maximum that represent the "base cases" for that model.  "Edge cases" should be created on the fly, within the context of the test which it is needed.
  - For tests that require a large number of fixture records to be created, use Rails helpers to help create the records needed for the test, then inline the creation. For example, [entries_test_helper.rb](test/support/entries_test_helper.rb) provides helpers to easily do this.

- **Write minimal, effective tests**
  - Use system tests sparingly as they increase the time to complete the test suite
  - Only write tests for critical and important code paths
  - Write tests as you go, when required
  - Take a practical approach to testing.  Tests are effective when their presence _significantly increases confidence in the codebase_.

  Below are examples of necessary vs. unnecessary tests:

  ```rb
  # GOOD!!
  # Necessary test - in this case, we're testing critical domain business logic
  test "syncs balances" do
    Holding::Syncer.any_instance.expects(:sync_holdings).returns([]).once

    @account.expects(:start_date).returns(2.days.ago.to_date)

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(
      [
        Balance.new(date: 1.day.ago.to_date, balance: 1000, cash_balance: 1000, currency: "USD"),
        Balance.new(date: Date.current, balance: 1000, cash_balance: 1000, currency: "USD")
      ]
    )

    assert_difference "@account.balances.count", 2 do
      Balance::Syncer.new(@account, strategy: :forward).sync_balances
    end
  end

  # BAD!!
  # Unnecessary test - in this case, this is simply testing ActiveRecord's functionality
  test "saves balance" do 
    balance_record = Balance.new(balance: 100, currency: "USD")

    assert balance_record.save
  end
  ```

- **Test boundaries correctly**
  - Distinguish between commands and query methods. Test output of query methods; test that commands were called with the correct params. See an example below:

  ```rb
  class ExampleClass
    def do_something
      result = 2 + 2

      CustomEventProcessor.process_result(result)

      result
    end
  end

  class ExampleClass < ActiveSupport::TestCase
    test "boundaries are tested correctly" do 
      result = ExampleClass.new.do_something

      # GOOD - we're only testing that the command was received, not internal implementation details
      # The actual tests for CustomEventProcessor belong in a different test suite!
      CustomEventProcessor.expects(:process_result).with(4).once

      # GOOD - we're testing the implementation of ExampleClass inside its own test suite
      assert_equal 4, result
    end
  end
  ```

  - Never test the implementation details of one class in another classes test suite

- **Stubs and mocks**
  - Use `mocha` gem
  - Always prefer `OpenStruct` when creating mock instances, or in complex cases, a mock class
  - Only mock what's necessary. If you're not testing return values, don't mock a return value.
```

---

## Original File: .cursor/rules/ui-ux-design-guidelines.mdc

```markdown
---
description: This file describes Sure's design system and how views should be styled
globs: app/views/**,app/helpers/**,app/javascript/controllers/**
alwaysApply: true
---
Use the rules below when:

- You are writing HTML
- You are writing CSS
- You are writing styles in a JavaScript Stimulus controller

## Rules for AI (mandatory)

The codebase uses TailwindCSS v4.x (the newest version) with a custom design system defined in [maybe-design-system.css](app/assets/tailwind/maybe-design-system.css)

- Always start by referencing [maybe-design-system.css](app/assets/tailwind/maybe-design-system.css) to see the base primitives, functional tokens, and component tokens we use in the codebase
- Always prefer using the functional "tokens" defined in @maybe-design-system.css when possible.
  - Example 1: use `text-primary` rather than `text-white`
  - Example 2: use `bg-container` rather than `bg-white`
  - Example 3: use `border border-primary` rather than `border border-gray-200`
- Never create new styles in [maybe-design-system.css](app/assets/tailwind/maybe-design-system.css) or [application.css](app/assets/tailwind/application.css) without explicitly receiving permission to do so
- Always generate semantic HTML
```

---

## Original File: .cursor/rules/stimulus_conventions.mdc

```markdown
---
description: 
globs: 
alwaysApply: false
---
This rule describes how to write Stimulus controllers.

- **Use declarative actions, not imperative event listeners**
  - Instead of assigning a Stimulus target and binding it to an event listener in the initializer, always write Controllers + ERB views declaratively by using Stimulus actions in ERB to call methods in the Stimulus JS controller.  Below are good vs. bad code.

  BAD code:

  ```js
  // BAD!!!! DO NOT DO THIS!!
  // Imperative - controller does all the work
  export default class extends Controller {
    static targets = ["button", "content"]

    connect() {
      this.buttonTarget.addEventListener("click", this.toggle.bind(this))
    }

    toggle() {
      this.contentTarget.classList.toggle("hidden")
      this.buttonTarget.textContent = this.contentTarget.classList.contains("hidden") ? "Show" : "Hide"
    }
  }
  ```

  GOOD code:

  ```erb
  <!-- Declarative - HTML declares what happens -->

  <div data-controller="toggle">
    <button data-action="click->toggle#toggle" data-toggle-target="button">Show</button>
    <div data-toggle-target="content" class="hidden">Hello World!</div>
  </div>
  ```

  ```js
  // Declarative - controller just responds
  export default class extends Controller {
    static targets = ["button", "content"]

    toggle() {
      this.contentTarget.classList.toggle("hidden")
      this.buttonTarget.textContent = this.contentTarget.classList.contains("hidden") ? "Show" : "Hide"
    }
  }
  ```

- **Keep Stimulus controllers lightweight and simple**
  - Always aim for less than 7 controller targets. Any more is a sign of too much complexity.
  - Use private methods and expose a clear public API

- **Keep Stimulus controllers focused on what they do best**
  - Domain logic does NOT belong in a Stimulus controller
  - Stimulus controllers should aim for a single responsibility, or a group of highly related responsibilities
  - Make good use of Stimulus's callbacks, actions, targets, values, and classes

- **Component controllers should not be used outside the component**
  - If a Stimulus controller is in the app/components directory, it should only be used in its component view. It should not be used anywhere in app/views.
```

---

## Original File: .cursor/rules/view_conventions.mdc

```
---
description: 
globs: app/views/**,app/javascript/**,app/components/**/*.js
alwaysApply: false
---
Use this rule to learn how to write ERB views, partials, and Stimulus controllers should be incorporated into them.

- **Component vs. Partial Decision Making**
  - **Use ViewComponents when:**
    - Element has complex logic or styling patterns
    - Element will be reused across multiple views/contexts
    - Element needs structured styling with variants/sizes (like buttons, badges)
    - Element requires interactive behavior or Stimulus controllers
    - Element has configurable slots or complex APIs
    - Element needs accessibility features or ARIA support
  
  - **Use Partials when:**
    - Element is primarily static HTML with minimal logic
    - Element is used in only one or few specific contexts
    - Element is simple template content (like CTAs, static sections)
    - Element doesn't need variants, sizes, or complex configuration
    - Element is more about content organization than reusable functionality

- **Prefer components over partials**
  - If there is a component available for the use case in app/components, use it
  - If there is no component, look for a partial
  - If there is no partial, decide between component or partial based on the criteria above

- **Examples of Component vs. Partial Usage**
  ```erb
  <%# Component: Complex, reusable with variants and interactivity %>
  <%= render DialogComponent.new(variant: :drawer) do |dialog| %>
    <% dialog.with_header(title: "Account Settings") %>
    <% dialog.with_body { "Dialog content here" } %>
  <% end %>
  
  <%# Component: Interactive with complex styling options %>
  <%= render ButtonComponent.new(text: "Save Changes", variant: "primary", confirm: "Are you sure?") %>
  
  <%# Component: Reusable with variants %>
  <%= render FilledIconComponent.new(icon: "credit-card", variant: :surface) %>
  
  <%# Partial: Static template content %>
  <%= render "shared/logo" %>
  
  <%# Partial: Simple, context-specific content with basic styling %>
  <%= render "shared/trend_change", trend: @account.trend, comparison_label: "vs last month" %>
  
  <%# Partial: Simple divider/utility %>
  <%= render "shared/ruler", classes: "my-4" %>
  
  <%# Partial: Simple form utility %>
  <%= render "shared/form_errors", model: @account %>
  ```

- **Keep domain logic out of the views**
   ```erb
    <%# BAD!!! %>

    <%# This belongs in the component file, not the template file! %>
    <% button_classes = { class: "bg-blue-500 hover:bg-blue-600" } %>

    <%= tag.button class: button_classes do %>
      Save Account
    <% end %>

    <%# GOOD! %>

    <%= tag.button class: computed_button_classes do %>
      Save Account
    <% end %>
    ```

- **Stimulus Integration in Views**
  - Always use the **declarative approach** when integrating Stimulus controllers
  - The ERB template should declare what happens, the Stimulus controller should respond
  - Refer to [stimulus_conventions.mdc](#original-file-cursorrulesstimulus_conventionsmdc) to learn how to incorporate them into 

  GOOD Stimulus controller integration into views:

  ```erb
  <!-- Declarative - HTML declares what happens -->

  <div data-controller="toggle">
    <button data-action="click->toggle#toggle" data-toggle-target="button">Show</button>
    <div data-toggle-target="content" class="hidden">Hello World!</div>
  </div>
  ```

- **Stimulus Controller Placement Guidelines**
  - **Component controllers** (in `app/components/`) should only be used within their component templates
  - **Global controllers** (in `app/javascript/controllers/`) can be used across any view
  - Pass data from Rails to Stimulus using `data-*-value` attributes, not inline JavaScript
  - Use Stimulus targets to reference DOM elements, not manual `getElementById` calls

- **Naming Conventions**
  - **Components**: Use `ComponentName` suffix (e.g., `ButtonComponent`, `DialogComponent`, `FilledIconComponent`)
  - **Partials**: Use underscore prefix (e.g., `_trend_change.html.erb`, `_form_errors.html.erb`, `_sync_indicator.html.erb`)
  - **Shared partials**: Place in `app/views/shared/` directory for reusable content
  - **Context-specific partials**: Place in relevant controller view directory (e.g., `accounts/_account_sidebar_tabs.html.erb`)
```

---

## Original File: .cursor/rules/cursor_rules.mdc

```
---
description: Guidelines for creating and maintaining Cursor rules to ensure consistency and effectiveness.
globs: .cursor/rules/*.mdc
alwaysApply: true
---

- **Required Rule Structure:**
  ```markdown
  ---
  description: Clear, one-line description of what the rule enforces
  globs: path/to/files/*.ext, other/path/**/*
  alwaysApply: boolean
  ---

  - **Main Points in Bold**
    - Sub-points with details
    - Examples and explanations
  ```

- **File References:**
  - Use `[filename](mdc:path/to/file)` ([filename](mdc:filename)) to reference files
  - Example: [prisma.mdc](.cursor/rules/prisma.mdc) for rule references
  - Example: [schema.prisma](prisma/schema.prisma) for code references

- **Code Examples:**
  - Use language-specific code blocks
  ```typescript
  // ✅ DO: Show good examples
  const goodExample = true;
  
  // ❌ DON'T: Show anti-patterns
  const badExample = false;
  ```

- **Rule Content Guidelines:**
  - Start with high-level overview
  - Include specific, actionable requirements
  - Show examples of correct implementation
  - Reference existing code when possible
  - Keep rules DRY by referencing other rules

- **Rule Maintenance:**
  - Update rules when new patterns emerge
  - Add examples from actual codebase
  - Remove outdated patterns
  - Cross-reference related rules

- **Best Practices:**
  - Use bullet points for clarity
  - Keep descriptions concise
  - Include both DO and DON'T examples
  - Reference actual code over theoretical examples
  - Use consistent formatting across rules
```

---

## Original File: .cursor/rules/self_improve.mdc

```
---
description: Guidelines for continuously improving Cursor rules based on emerging code patterns and best practices.
globs: **/*
alwaysApply: true
---

- **Rule Improvement Triggers:**
  - New code patterns not covered by existing rules
  - Repeated similar implementations across files
  - Common error patterns that could be prevented
  - New libraries or tools being used consistently
  - Emerging best practices in the codebase

- **Analysis Process:**
  - Compare new code with existing rules
  - Identify patterns that should be standardized
  - Look for references to external documentation
  - Check for consistent error handling patterns
  - Monitor test patterns and coverage

- **Rule Updates:**
  - **Add New Rules When:**
    - A new technology/pattern is used in 3+ files
    - Common bugs could be prevented by a rule
    - Code reviews repeatedly mention the same feedback
    - New security or performance patterns emerge

  - **Modify Existing Rules When:**
    - Better examples exist in the codebase
    - Additional edge cases are discovered
    - Related rules have been updated
    - Implementation details have changed

- **Example Pattern Recognition:**
  ```typescript
  // If you see repeated patterns like:
  const data = await prisma.user.findMany({
    select: { id: true, email: true },
    where: { status: 'ACTIVE' }
  });
  
  // Consider adding to [prisma.mdc](.cursor/rules/prisma.mdc):
  // - Standard select fields
  // - Common where conditions
  // - Performance optimization patterns
  ```

- **Rule Quality Checks:**
  - Rules should be actionable and specific
  - Examples should come from actual code
  - References should be up to date
  - Patterns should be consistently enforced

- **Continuous Improvement:**
  - Monitor code review comments
  - Track common development questions
  - Update rules after major refactors
  - Add links to relevant documentation
  - Cross-reference related rules

- **Rule Deprecation:**
  - Mark outdated patterns as deprecated
  - Remove rules that no longer apply
  - Update references to deprecated rules
  - Document migration paths for old patterns

- **Documentation Updates:**
  - Keep examples synchronized with code
  - Update references to external docs
  - Maintain links between related rules
  - Document breaking changes

Follow [cursor_rules.mdc](#original-file-cursorrulescursor_rulesmdc) for proper rule formatting and structure.
```
