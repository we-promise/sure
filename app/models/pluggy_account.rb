# frozen_string_literal: true

class PluggyAccount < ApplicationRecord
  include CurrencyNormalizable
  include PluggyAccount::DataHelpers

  belongs_to :pluggy_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  # Idempotent class entry-point: find-or-initialize by Pluggy account id,
  # link the parent item, then delegate field mapping to the instance method.
  # Bridges the plan's class-form contract (used by PluggyItem::Importer) with
  # the repo's instance-mapper idiom (cf. Wise/IBKR/Indexa/Questrade/Snaptrade).
  def self.upsert_from_pluggy!(account_data, pluggy_item:)
    data = new.send(:sdk_object_to_hash, account_data).with_indifferent_access
    account_id = (data[:id] || data[:account_id])&.to_s

    find_or_initialize_by(pluggy_account_id: account_id).tap do |account|
      account.pluggy_item = pluggy_item
      account.upsert_from_pluggy!(account_data)
    end
  end

  def upsert_from_pluggy!(account_data)
    # Convert SDK object to hash if needed
    data = sdk_object_to_hash(account_data).with_indifferent_access

    update!(
      pluggy_account_id: (data[:id] || data[:account_id])&.to_s,
      name: data[:name] || data[:account_name],
      account_number: data[:number] || data[:account_number],
      current_balance: parse_decimal(data[:balance] || data[:current_balance]),
      # Pluggy exposes currency on `currencyCode`; fall back to extract_currency
      # (handles a `currency` Hash/string) then "USD" — never default BRL→USD.
      currency: data[:currencyCode].presence || extract_currency(data, fallback: "USD"),
      account_status: data[:status] || data[:account_status],
      account_type: data[:type] || data[:account_type],
      provider: data[:provider] || data[:brokerage_name],
      institution_metadata: extract_institution_metadata(data),
      raw_payload: account_data
    )
  end

  def upsert_pluggy_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  def upsert_pluggy_holdings_snapshot!(holdings)
    update!(raw_holdings_payload: holdings, last_holdings_sync: Time.current)
  end

  def upsert_pluggy_activities_snapshot!(activities)
    update!(raw_activities_payload: activities, last_activities_sync: Time.current)
  end

  private

    def extract_institution_metadata(data)
      {
        name: data[:institution_name] || data.dig(:institution, :name),
        logo: data[:institution_logo] || data.dig(:institution, :logo),
        domain: data[:institution_domain] || data.dig(:institution, :domain)
      }.compact
    end

    def enqueue_connection_cleanup
      return unless pluggy_item

      PluggyConnectionCleanupJob.perform_later(
        pluggy_item_id: pluggy_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Pluggy account #{id}, defaulting to USD")
    end
end
