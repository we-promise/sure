# Per-Family Provider Generator & System Guide

This guide explains how to use the new per-family provider system, which makes it easy to add new provider integrations with family-scoped credentials.

## Table of Contents
1. [Quick Start](#quick-start)
2. [What Gets Generated](#what-gets-generated)
3. [How It Works](#how-it-works)
4. [Customization](#customization)
5. [Examples](#examples)

---

## Quick Start

### Generate a New Per-Family Provider

```bash
rails g provider:family PROVIDER_NAME field:type[:secret] field:type[:secret] ...
```

### Example: Adding a MyBank Provider

```bash
rails g provider:family my_bank \
  api_key:text:secret \
  base_url:string \
  refresh_token:text:secret
```

This single command generates:
- ✅ Migration for `my_bank_items` and `my_bank_accounts` tables
- ✅ Models: `MyBankItem`, `MyBankAccount`, and `MyBankItem::Provided` concern
- ✅ Adapter with `Provider::PerFamilyConfigurable`
- ✅ Panel view for provider settings
- ✅ Controller with CRUD actions
- ✅ Routes
- ✅ Updates to settings controller and view

---

## What Gets Generated

### 1. Migration

**File:** `db/migrate/xxx_create_my_bank_tables_and_accounts.rb`

Creates two complete tables with all necessary fields:

```ruby
class CreateMyBankTablesAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :my_bank_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      # Institution metadata
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      # Status and lifecycle
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false

      # Sync settings
      t.datetime :sync_start_date

      # Raw data storage
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      # Provider-specific credential fields
      t.text :api_key
      t.string :base_url
      t.text :refresh_token

      t.timestamps
    end

    add_index :my_bank_items, :family_id
    add_index :my_bank_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :my_bank_accounts, id: :uuid do |t|
      t.references :my_bank_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :account_id

      # Account details
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :my_bank_accounts, :account_id
    add_index :my_bank_accounts, :my_bank_item_id
  end
end
```

### 2. Models

**File:** `app/models/my_bank_item.rb`

The item model stores per-family connection credentials:

```ruby
class MyBankItem < ApplicationRecord
  include Syncable, Provided
  include Provider::PerFamilyItem

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encryption for secret fields
  if Rails.application.credentials.active_record_encryption.present?
    encrypts :api_key, :refresh_token, deterministic: true
  end

  validates :name, presence: true
  validates :api_key, presence: true, on: :create
  validates :refresh_token, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo
  has_many :my_bank_accounts, dependent: :destroy
  has_many :accounts, through: :my_bank_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }

  def credentials_configured?
    api_key.present? && refresh_token.present?
  end

  def effective_base_url
    base_url.presence || "https://api.mybank.com"
  end
end
```

**File:** `app/models/my_bank_account.rb`

The account model stores individual account data from the provider:

```ruby
class MyBankAccount < ApplicationRecord
  include CurrencyNormalizable

  belongs_to :my_bank_item

  # Association through account_providers for linking to internal accounts
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  def upsert_my_bank_snapshot!(account_snapshot)
    update!(
      current_balance: account_snapshot[:balance],
      currency: parse_currency(account_snapshot[:currency]) || "USD",
      name: account_snapshot[:name],
      account_id: account_snapshot[:id]&.to_s,
      account_status: account_snapshot[:status],
      raw_payload: account_snapshot
    )
  end
end
```

**File:** `app/models/my_bank_item/provided.rb`

The Provided concern connects the item to its provider SDK:

```ruby
module MyBankItem::Provided
  extend ActiveSupport::Concern

  def my_bank_provider
    return nil unless credentials_configured?

    Provider::MyBank.new(
      api_key,
      base_url: effective_base_url,
      refresh_token: refresh_token
    )
  end
end
```

### 3. Adapter

**File:** `app/models/provider/my_bank_adapter.rb`

```ruby
class Provider::MyBankAdapter < Provider::Base
  include Provider::PerFamilyConfigurable

  configure_per_family do
    description <<~DESC
      Setup instructions for My Bank:
      1. Visit your My Bank dashboard to get your credentials
      2. Enter your credentials below to enable My Bank sync
      3. After successful configuration, go to the Accounts tab to link accounts
    DESC

    field :api_key,
          label: "API Key",
          type: :text,
          secret: true,
          required: true,
          description: "Your My Bank API key"

    field :base_url,
          label: "Base URL",
          type: :string,
          description: "Your My Bank base url"

    field :refresh_token,
          label: "Refresh Token",
          type: :text,
          secret: true,
          required: true,
          description: "Your My Bank refresh token"
  end

  def self.build_provider(family:)
    return nil unless family.present?
    item = family.my_bank_items.where.not(api_key: nil).first
    return nil unless item&.credentials_configured?

    # TODO: Implement provider initialization
    Provider::MyBank.new(item.api_key)
  end
end
```

### 4. Panel View

**File:** `app/views/settings/providers/_my_bank_panel.html.erb`

```erb
<%# Auto-generated panel using PerFamilyConfigurable configuration %>
<%= render_per_family_provider_panel(:my_bank, error_message: @error_message) %>
```

### 5. Controller

**File:** `app/controllers/my_bank_items_controller.rb`

```ruby
class MyBankItemsController < ApplicationController
  include Provider::PerFamilyItemController

  # Provides standard CRUD actions:
  # - create (POST /my_bank_items)
  # - update (PATCH /my_bank_items/:id)
  # - destroy (DELETE /my_bank_items/:id)
  # - sync (POST /my_bank_items/:id/sync)
end
```

### 6. Routes

**File:** `config/routes.rb` (updated)

```ruby
resources :my_bank_items, only: [:create, :update, :destroy] do
  member do
    post :sync
  end
end
```

### 7. Settings Updates

**File:** `app/controllers/settings/providers_controller.rb` (updated)
- Excludes `my_bank` from global provider configurations
- Adds `@my_bank_items` instance variable

**File:** `app/views/settings/providers/show.html.erb` (updated)
- Adds My Bank section with turbo frame

---

## How It Works

### The Magic: Provider::PerFamilyConfigurable

The `configure_per_family` DSL block defines the fields your provider needs. This configuration is used to:

1. **Auto-generate forms** - The panel view automatically renders form fields
2. **Document requirements** - Clear description and field labels
3. **Handle encryption** - Secret fields are marked for password input
4. **Validate requirements** - Required fields are marked

### Field Types

```ruby
field :field_name,
      label: "Human-readable Label",
      type: :text | :string | :integer | :boolean,
      required: true | false,
      secret: true | false,  # Will use password input and be encrypted
      default: "default value",
      description: "Help text for the field",
      placeholder: "Placeholder text"
```

### Auto-Generated Forms

The `render_per_family_provider_panel` helper reads the configuration and generates:
- Setup instructions (from description)
- Form fields (from field definitions)
- Field descriptions
- Submit button
- Success indicator

---

## Customization

### Customize the Adapter

After generation, edit `app/models/provider/my_bank_adapter.rb`:

```ruby
# Update the configure_per_family block
configure_per_family do
  description <<~DESC
    **Custom instructions:**
    1. Go to Settings > API in your My Bank dashboard
    2. Generate a new API key
    3. Copy the key and paste it below

    **Important:** Keep your API key secure!
  DESC

  field :api_key,
        label: "API Key",
        type: :text,
        secret: true,
        required: true,
        description: "Your unique API key from My Bank dashboard",
        placeholder: "Enter your API key"
end

# Implement the build_provider method
def self.build_provider(family:)
  return nil unless family.present?

  item = family.my_bank_items.where.not(api_key: nil).first
  return nil unless item&.credentials_configured?

  Provider::MyBank.new(
    item.api_key,
    base_url: item.effective_base_url,
    refresh_token: item.refresh_token
  )
end
```

### Update the Model

**File:** `app/models/my_bank_item.rb`

Add encryption, validations, and helper methods:

```ruby
class MyBankItem < ApplicationRecord
  include Syncable, Provided
  include Provider::PerFamilyItem

  belongs_to :family

  # Encryption for secret fields
  if Rails.application.credentials.active_record_encryption.present?
    encrypts :api_key, :refresh_token, deterministic: true
  end

  # Validations
  validates :name, presence: true
  validates :api_key, presence: true, on: :create
  validates :refresh_token, presence: true, on: :create

  # Helper methods
  def credentials_configured?
    api_key.present? && refresh_token.present?
  end

  def effective_base_url
    base_url.presence || "https://api.mybank.com"
  end
end
```

### Customize the Controller

If you need custom logic beyond basic CRUD:

```ruby
class MyBankItemsController < ApplicationController
  include Provider::PerFamilyItemController

  # Override to add custom behavior
  def handle_successful_save(action)
    super

    # Trigger initial sync after creation
    @item.sync_later if action == :create
  end

  # Add custom actions
  def refresh_token
    @item = Current.family.my_bank_items.find(params[:id])

    if @item.refresh_oauth_token!
      redirect_to settings_providers_path, notice: "Token refreshed successfully"
    else
      redirect_to settings_providers_path, alert: "Failed to refresh token"
    end
  end

  private

  # Customize permitted params
  def permitted_params
    params.require(:my_bank_item).permit(
      :name, :api_key, :base_url, :refresh_token, :sync_start_date
    )
  end
end
```

### Customize the View

If you need more than the auto-generated panel, create a custom partial:

**File:** `app/views/settings/providers/_my_bank_panel.html.erb`

```erb
<div class="space-y-4">
  <%# Custom header %>
  <div class="flex items-center gap-3">
    <%= image_tag "my_bank_logo.svg", class: "w-8 h-8" %>
    <h3 class="text-lg font-semibold">My Bank Integration</h3>
  </div>

  <%# Use helper for most of the form %>
  <%= render_per_family_provider_panel(:my_bank, error_message: @error_message) %>

  <%# Add custom content %>
  <div class="mt-4 p-4 bg-subtle rounded-lg">
    <p class="text-sm text-secondary">
      Need help? Visit <a href="https://help.mybank.com" class="link">My Bank Help Center</a>
    </p>
  </div>
</div>
```

---

## Examples

### Example 1: Simple API Key Provider

```bash
rails g provider:family coinbase api_key:text:secret
```

Result: Basic provider with just an API key field.

### Example 2: OAuth Provider

```bash
rails g provider:family stripe \
  client_id:string:secret \
  client_secret:string:secret \
  access_token:text:secret \
  refresh_token:text:secret
```

Then customize the adapter to implement OAuth flow.

### Example 3: Complex Provider

```bash
rails g provider:family enterprise_bank \
  api_key:text:secret \
  environment:string \
  base_url:string \
  webhook_secret:text:secret \
  rate_limit:integer
```

Then add custom validations and logic in the model:

```ruby
class EnterpriseBankItem < ApplicationRecord
  # ... (basic setup)

  validates :environment, inclusion: { in: %w[sandbox production] }
  validates :rate_limit, numericality: { greater_than: 0 }, allow_nil: true

  def effective_rate_limit
    rate_limit || 100  # Default to 100 requests/minute
  end
end
```

---

## Comparison: Manual vs Generated

### Manual Approach (Old Way)

**Time:** ~2-3 hours
**Files to create/edit:** 8+
**Lines of code:** ~500+
**Error-prone:** Yes (easy to miss steps)

### Generated Approach (New Way)

**Time:** ~5-10 minutes
**Files to create/edit:** 1 (model customization)
**Lines of code:** ~50 (customization only)
**Error-prone:** No (generator handles boilerplate)

---

## Tips & Best Practices

### 1. Always Run Migrations

```bash
rails db:migrate
```

### 2. Test in Console

```ruby
# Check if adapter is registered
Provider::Factory.adapters
# => { ... "MyBankAccount" => Provider::MyBankAdapter, ... }

# Check configuration
Provider::MyBankAdapter.per_family_configuration.fields
# => [#<Provider::PerFamilyConfigurable::PerFamilyConfigField...>]

# Test provider building
family = Family.first
item = family.my_bank_items.create!(name: "Test", api_key: "test_key")
provider = Provider::MyBankAdapter.build_provider(family: family)
```

### 3. Use Proper Encryption

Always check that encryption is set up:

```ruby
# In your model
if Rails.application.credentials.active_record_encryption.present?
  encrypts :api_key, :refresh_token, deterministic: true
else
  Rails.logger.warn "ActiveRecord encryption not configured for #{self.name}"
end
```

### 4. Implement Proper Error Handling

```ruby
def self.build_provider(family:)
  return nil unless family.present?

  item = family.my_bank_items.where.not(api_key: nil).first
  return nil unless item&.credentials_configured?

  begin
    Provider::MyBank.new(item.api_key)
  rescue Provider::MyBank::ConfigurationError => e
    Rails.logger.error("MyBank provider configuration error: #{e.message}")
    nil
  end
end
```

### 5. Add Integration Tests

```ruby
# test/models/provider/my_bank_adapter_test.rb
class Provider::MyBankAdapterTest < ActiveSupport::TestCase
  test "builds provider with valid credentials" do
    family = families(:family_one)
    item = family.my_bank_items.create!(
      name: "Test Bank",
      api_key: "test_key"
    )

    provider = Provider::MyBankAdapter.build_provider(family: family)
    assert_not_nil provider
    assert_instance_of Provider::MyBank, provider
  end

  test "returns nil without credentials" do
    family = families(:family_one)
    provider = Provider::MyBankAdapter.build_provider(family: family)
    assert_nil provider
  end
end
```

---

## Troubleshooting

### Panel Not Showing

1. Check that the provider is excluded in `settings/providers_controller.rb`:
   ```ruby
   @provider_configurations = Provider::ConfigurationRegistry.all.reject do |config|
     config.provider_key.to_s.casecmp("my_bank").zero?
   end
   ```

2. Check that the instance variable is set:
   ```ruby
   @my_bank_items = Current.family.my_bank_items.ordered.select(:id)
   ```

3. Check that the section exists in `settings/providers/show.html.erb`:
   ```erb
   <%= settings_section title: "My Bank" do %>
     <turbo-frame id="my-bank-providers-panel">
       <%= render "settings/providers/my_bank_panel" %>
     </turbo-frame>
   <% end %>
   ```

### Form Not Submitting

1. Check routes are properly added:
   ```bash
   rails routes | grep my_bank
   ```

2. Check controller includes the concern:
   ```ruby
   class MyBankItemsController < ApplicationController
     include Provider::PerFamilyItemController
   ```

3. Check turbo frame ID matches:
   - View: `<turbo-frame id="my-bank-providers-panel">`
   - Controller: Uses `"my-bank-providers-panel"` in turbo_stream.replace

### Encryption Not Working

1. Check credentials are configured:
   ```bash
   rails credentials:edit
   ```

2. Add encryption keys if missing:
   ```yaml
   active_record_encryption:
     primary_key: (generate with: rails db:encryption:init)
     deterministic_key: (generate with: rails db:encryption:init)
     key_derivation_salt: (generate with: rails db:encryption:init)
   ```

3. Or use environment variables:
   ```bash
   export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="..."
   export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="..."
   export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="..."
   ```

---

## Advanced: Creating a Provider SDK

For complex providers, consider creating a separate SDK class:

```ruby
# app/models/provider/my_bank.rb
class Provider::MyBank
  class AuthenticationError < StandardError; end
  class RateLimitError < StandardError; end

  def initialize(api_key, base_url: "https://api.mybank.com")
    @api_key = api_key
    @base_url = base_url
    @client = HTTP.headers(
      "Authorization" => "Bearer #{api_key}",
      "User-Agent" => "MyApp/1.0"
    )
  end

  def get_accounts
    response = @client.get("#{@base_url}/accounts")
    handle_response(response)
  end

  def get_transactions(account_id, start_date: nil, end_date: nil)
    params = { account_id: account_id }
    params[:start_date] = start_date.iso8601 if start_date
    params[:end_date] = end_date.iso8601 if end_date

    response = @client.get("#{@base_url}/transactions", params: params)
    handle_response(response)
  end

  private

  def handle_response(response)
    case response.code
    when 200...300
      JSON.parse(response.body, symbolize_names: true)
    when 401, 403
      raise AuthenticationError, "Invalid API key"
    when 429
      raise RateLimitError, "Rate limit exceeded"
    else
      raise StandardError, "API error: #{response.code} #{response.body}"
    end
  end
end
```

---

## Summary

The per-family provider generator system provides:

✅ **Fast development** - Generate in seconds, not hours
✅ **Consistency** - All providers follow the same pattern
✅ **Maintainability** - Clear structure and conventions
✅ **Flexibility** - Easy to customize for complex needs
✅ **Security** - Built-in encryption for sensitive fields
✅ **Documentation** - Self-documenting with descriptions

Use it whenever you need to add a new provider where each family needs their own credentials.
