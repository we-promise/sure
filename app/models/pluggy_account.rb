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

  # Default account-type option for the "Set up your Pluggy accounts" wizard.
  # Maps Pluggy's raw `account_type` (e.g. "credit_card", "depository",
  # "investment", "loan", "real_estate", "mortgage") to one of the option
  # strings PluggyItemsController#complete_account_setup reads and
  # infer_accountable_type understands — depository / credit_card / loan /
  # investment / other_asset — so each wizard row's <select> pre-selects a
  # sane value. Tolerant substring match so unknown upstream types still get a
  # default instead of blocking setup.
  def suggested_setup_account_type
    s = account_type.to_s.downcase
    return "credit_card" if s.include?("credit")
    return "loan"        if s.include?("loan") || s.include?("mortgage")
    return "investment"  if s.include?("invest")
    return "other_asset" if s.include?("real_estate") || s.include?("property") || s.include?("asset")
    "depository"
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
  #
  # The find is scoped to THIS pluggy_item's accounts. An unscoped
  # `find_or_initialize_by(pluggy_account_id:)` is global across every PluggyItem
  # in the DB, so on a reconnect (the same upstream account linked to a second
  # PluggyItem) it would resolve to the OTHER item's row and the
  # `account.pluggy_item = pluggy_item` assignment below would silently re-parent
  # it — stealing another connection's account. Scoping to the association makes
  # the lookup per-item; the composite-unique index on
  # [pluggy_item_id, pluggy_account_id] (see the migration) enforces this at the
  # DB level. The `account.pluggy_item = pluggy_item` write is now always a
  # no-op for found rows and the setter for initialized ones.
  def self.upsert_from_pluggy!(account_data, pluggy_item:)
    data = new.send(:sdk_object_to_hash, account_data).with_indifferent_access
    account_id = (data[:id] || data[:account_id])&.to_s

    pluggy_item.pluggy_accounts.find_or_initialize_by(pluggy_account_id: account_id).tap do |account|
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
