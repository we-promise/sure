# frozen_string_literal: true

class RedbarkAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include RedbarkAccount::DataHelpers

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :redbark_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, :redbark_account_id, presence: true
  validates :redbark_account_id, uniqueness: { scope: :redbark_item_id }

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :needs_setup, -> { without_linked.where(ignored: false) }
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

  # Redbark accounts endpoint returns:
  # { id, connectionId, provider, name, type, institutionName, accountNumber, currency }
  # Balance is not included there - it comes from the balances endpoint and is
  # written separately by the importer, so it is deliberately not touched here.
  def upsert_from_redbark!(account_data, connection_data: nil)
    data = sdk_object_to_hash(account_data).with_indifferent_access
    connection = connection_data.present? ? sdk_object_to_hash(connection_data).with_indifferent_access : {}

    display_name = if data[:institutionName].present?
      "#{data[:institutionName]} - #{data[:name]}"
    else
      data[:name]
    end

    update!(
      redbark_account_id: data[:id]&.to_s,
      connection_id: data[:connectionId]&.to_s,
      name: display_name,
      account_number: data[:accountNumber],
      currency: extract_currency(data, fallback: parse_currency(currency) || "AUD"),
      account_status: connection[:status],
      account_type: data[:type],
      provider: data[:provider],
      institution_metadata: {
        name: data[:institutionName] || connection[:institutionName],
        logo: connection[:institutionLogo]
      }.compact,
      raw_payload: account_data
    )
  end

  def upsert_redbark_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def enqueue_connection_cleanup
      return unless redbark_item

      RedbarkConnectionCleanupJob.perform_later(
        redbark_item_id: redbark_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Redbark account #{id}, defaulting to AUD")
    end
end
