# frozen_string_literal: true

class IndexaCapitalAccount < ApplicationRecord
  include CurrencyNormalizable
  include IndexaCapitalAccount::DataHelpers

  belongs_to :indexa_capital_item

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

  def upsert_from_indexa_capital!(account_data)
    data = sdk_object_to_hash(account_data).with_indifferent_access

    # Indexa Capital API field mapping:
    # account_number → unique account identifier
    # name → display name (constructed by provider)
    # type → mutual / pension / epsv
    # status → active / inactive
    # currency → always EUR for Indexa Capital
    attrs = {
      indexa_capital_account_id: data[:account_number]&.to_s,
      account_number: data[:account_number]&.to_s,
      name: data[:name] || "Indexa Capital Account",
      currency: data[:currency] || "EUR",
      account_status: data[:status],
      account_type: data[:type],
      provider: "Indexa Capital",
      raw_payload: account_data
    }
    attrs[:current_balance] = data[:current_balance].to_d unless data[:current_balance].nil?

    update!(attrs)
  end

  # Store holdings snapshot - return early if empty to avoid setting timestamps incorrectly
  def upsert_holdings_snapshot!(holdings_data)
    return if holdings_data.blank?

    update!(
      raw_holdings_payload: holdings_data,
      last_holdings_sync: Time.current
    )
  end

  # Store activities snapshot - return early if empty to avoid setting timestamps incorrectly
  def upsert_activities_snapshot!(activities_data)
    return if activities_data.blank?

    update!(
      raw_activities_payload: activities_data,
      last_activities_sync: Time.current
    )
  end

  private

    def enqueue_connection_cleanup
      return unless indexa_capital_item
      return unless indexa_capital_authorization_id.present?

      IndexaCapitalConnectionCleanupJob.perform_later(
        indexa_capital_item_id: indexa_capital_item.id,
        authorization_id: indexa_capital_authorization_id,
        account_id: id
      )
    end
end
