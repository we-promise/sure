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

  # Normalise a Redbark liability (CreditCard / Loan) `current_balance` into the
  # sign Sure stores: a positive amount owed (or a negative credit / overpaid
  # balance).
  #
  # Redbark does not normalise the sign across its upstream sources:
  #   * Fiskil (AU / CDR) reports the amount owed as a negative balance.
  #     Negate to store it as a positive amount owed (Redbark sample response:
  #     credit card "\"-842.15\"").
  #   * Plaid (US / CA) reports the amount owed as a POSITIVE balance for
  #     credit and loan accounts (https://plaid.com/docs/api/accounts/).
  #     Pass through unchanged. This is what the bug in we-promise/sure#3747
  #     mis-applies a blind negation to, flipping every Plaid-sourced
  #     liability and double-inflating net worth.
  #   * Any other or blank `provider` keeps Fiskil's negation convention
  #     (today's behaviour) AND records a DebugLogEntry on every call, so an
  #     operator can confirm or correct the convention for the new source.
  #
  # The check keys off `provider`, NOT the currency or institution country:
  # the reporter of we-promise/sure#3747 confirms that their Wise
  # Plaid-sourced accounts carry AUD and EUR alongside USD (upstream comment
  # 5920931841).
  #
  # The processor calls this for liability accountable types only; do not
  # call it for Depository / Investment — their balances pass through
  # unchanged regardless of provider.
  #
  # @param balance [BigDecimal, Numeric] the raw `current_balance` value the
  #   processor read off `#current_balance` for this account.
  # @param accountable_type [String] the accountable type of the Sure account
  #   being updated (e.g. "CreditCard"). Used only for the support metadata.
  # @param account [Account, nil] the Sure account, when available — attached
  #   to the DebugLogEntry capture so support can trace the affected account.
  # @return [BigDecimal, Numeric] the balance with the correct sign.
  def normalized_liability_balance(balance:, accountable_type: nil, account: nil)
    case (provider.presence&.downcase)
    when "fiskil"
      -balance
    when "plaid"
      balance
    else
      # Unknown / blank convention: keep the CDR convention (negate) and
      # record a DebugLogEntry so support can flag the source. Following
      # docs/llm-guides/providers.md, include category, level, message,
      # source, provider_key and useful structured metadata, and attach
      # family, account and account provider when available.
      # DebugLogEntry#capture is a safe no-op on error (log! is wrapped in
      # rescue), so a missing family or a capture failure cannot break a
      # balance update.
      DebugLogEntry.capture(
        category: "redbark_sync",
        level: "warn",
        message: "Redbark liability balance normalisation: unrecognised or blank " \
                 "provider — kept the Fiskil/CDR convention (negate). Operator should " \
                 "confirm the upstream source's sign convention before relying on " \
                 "stored liability balances.",
        source: "RedbarkAccount::Processor",
        provider_key: provider.presence,
        family: redbark_item&.family,
        account: account,
        account_provider: account_provider,
        metadata: {
          redbark_account_id: id,
          redbark_account_redbark_id: redbark_account_id,
          provider: provider,
          accountable_type: accountable_type,
          balance_in: balance,
          balance_out: -balance
        }
      )
      -balance
    end
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
