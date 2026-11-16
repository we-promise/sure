# frozen_string_literal: true

# The single account a Fio token reaches, as described by the statement header.
class FioAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  INSTITUTION_NAME = "Fio banka".freeze
  INSTITUTION_DOMAIN = "fio.cz".freeze

  # Fio's statement header has no product or type field, so every discovered account is
  # offered as a current account. The setup screen lets the user pick something else
  # (Provider::FioAdapter.supported_account_types) for a loan or mortgage token.
  DEFAULT_ACCOUNTABLE_TYPE = "Depository".freeze
  DEFAULT_SUBTYPE = "checking".freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    # Not deterministic: neither is ever looked up by value, and an IBAN is exactly the
    # kind of field worth keeping opaque at rest.
    encrypts :iban
  end

  belongs_to :fio_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :fio_account_id, uniqueness: { scope: :fio_item_id, allow_nil: true }

  # Fio accounts with no linked Sure account.
  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  # Unlinked accounts that still need a setup decision (i.e. not explicitly skipped).
  scope :needs_setup, -> { unlinked.where(ignored: false) }
  scope :ordered, -> { order(created_at: :desc) }
  # The linked Sure account, if any.
  def current_account
    account
  end

  def suggested_account_type
    DEFAULT_ACCOUNTABLE_TYPE
  end

  def suggested_subtype
    DEFAULT_SUBTYPE
  end

  # Idempotently create or update the AccountProvider link.
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear the cached nil.
    reload_account_provider
    account_provider
  end

  # Persist the statement header. `closingBalance` is the balance at the end of the
  # requested period, which for a window ending today is the current balance.
  def upsert_fio_snapshot!(statement_info)
    info = statement_info.to_h.with_indifferent_access
    account_number = info[:accountId].presence&.to_s

    update!(
      fio_account_id: account_number || fio_account_id,
      name: name.presence || default_name(account_number),
      bank_id: info[:bankId].presence&.to_s || bank_id,
      iban: info[:iban].presence || iban,
      bic: info[:bic].presence || bic,
      currency: parse_currency(info[:currency]) || currency,
      current_balance: parse_balance(info[:closingBalance]) || current_balance,
      institution_metadata: institution_metadata.presence || {
        "name" => INSTITUTION_NAME,
        "domain" => INSTITUTION_DOMAIN,
        "url" => "https://#{INSTITUTION_DOMAIN}"
      },
      raw_payload: info
    )
  end

  def upsert_fio_transactions_snapshot!(transactions_snapshot)
    update!(raw_transactions_payload: transactions_snapshot)
  end

  private

    # Fio names no account, so the account number stands in until the user renames it.
    def default_name(account_number)
      [ INSTITUTION_NAME, account_number ].compact_blank.join(" ")
    end

    def parse_balance(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      Rails.logger.warn("FioAccount - Unparseable balance #{value.inspect} for account #{id}")
      nil
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code #{currency_value.inspect} for Fio account #{id}")
    end
end
