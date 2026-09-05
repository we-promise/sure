class MonobankAccount < ApplicationRecord
  include CurrencyNormalizable, IsoNumericCurrency, Encryptable

  # Monobank card types (and jars) mapped onto Sure accountable types/subtypes.
  # Everything Monobank exposes on the personal API is a current account holding the
  # client's own money, so all of them land on Depository. A card with a credit limit is
  # still Depository rather than CreditCard: the limit is subtracted out of the balance
  # (see #upsert_monobank_snapshot!), leaving own funds, which is what Sure tracks for a
  # cash account.
  MONOBANK_ACCOUNT_TYPE_MAP = {
    "black" => { accountable_type: "Depository", subtype: "checking" },
    "white" => { accountable_type: "Depository", subtype: "checking" },
    "platinum" => { accountable_type: "Depository", subtype: "checking" },
    "iron" => { accountable_type: "Depository", subtype: "checking" },
    "yellow" => { accountable_type: "Depository", subtype: "checking" },
    "eaid" => { accountable_type: "Depository", subtype: "checking" },
    "fop" => { accountable_type: "Depository", subtype: "checking" },
    "jar" => { accountable_type: "Depository", subtype: "savings" }
  }.freeze

  JAR_KIND = "jar".freeze
  CARD_KIND = "card".freeze

  INSTITUTION_NAME = "Monobank".freeze
  INSTITUTION_DOMAIN = "monobank.ua".freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    # Not deterministic: neither column is ever looked up by value, and an IBAN plus a
    # partial card number are exactly the fields worth keeping opaque at rest.
    encrypts :masked_pan
    encrypts :iban
  end

  belongs_to :monobank_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :monobank_item_id, allow_nil: true }

  # Monobank accounts with no linked Sure account.
  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  # Unlinked accounts that still need a setup decision (i.e. not explicitly skipped).
  scope :needs_setup, -> { unlinked.where(ignored: false) }

  # The linked Sure account, if any.
  def current_account
    account
  end

  # True when this record is a savings jar rather than a card.
  def jar?
    account_kind == JAR_KIND
  end

  # Localized label for this account's Monobank product ("Black card", "Jar"), used in
  # the account pickers where the stored name may already have been renamed by the user.
  def type_label
    return I18n.t("monobank_account.card_types.jar") if jar?

    card_type_label(account_type)
  end

  # Suggested Sure accountable type for this account, or nil when the card type is
  # unrecognized (a new Monobank product), in which case setup asks the user.
  def suggested_account_type
    type_mapping&.fetch(:accountable_type, nil)
  end

  # Suggested Sure subtype (checking for cards, savings for jars), or nil.
  def suggested_subtype
    type_mapping&.[](:subtype)
  end

  # Persist the latest Monobank account snapshot.
  #
  # Monobank reports money in the currency's minor units and reports `balance` for a
  # card *including* its credit limit, so own funds are balance - creditLimit. Currency
  # arrives as an ISO 4217 numeric code (980), which is translated before the shared
  # currency normalizer sees it.
  def upsert_monobank_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    kind = snapshot[:kind].presence || CARD_KIND
    alpha_currency = alpha_currency_code(snapshot[:currencyCode])
    log_invalid_currency(snapshot[:currencyCode]) if snapshot[:currencyCode].present? && alpha_currency.blank?
    divisor = minor_unit_divisor(alpha_currency)

    raw_balance = to_decimal(snapshot[:balance])
    raw_credit_limit = to_decimal(snapshot[:creditLimit])

    assign_attributes(
      current_balance: (raw_balance - raw_credit_limit) / divisor,
      credit_limit: raw_credit_limit / divisor,
      currency: parse_currency(alpha_currency) || "UAH",
      name: display_name_for(snapshot, kind: kind),
      account_id: snapshot[:id],
      account_kind: kind,
      account_type: account_type_for(snapshot, kind: kind),
      masked_pan: Array(snapshot[:maskedPan]).first.presence,
      iban: snapshot[:iban].presence,
      provider: "monobank",
      institution_metadata: {
        name: INSTITUTION_NAME,
        domain: INSTITUTION_DOMAIN
      }.compact,
      raw_payload: account_snapshot
    )

    save!
  end

  # Persist the latest raw transactions payload for this account.
  def upsert_monobank_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def type_mapping
      MONOBANK_ACCOUNT_TYPE_MAP[account_type.to_s.downcase]
    end

    # Jars are typed "jar" so they get their own mapping and label; cards keep the type
    # Monobank reports ("black", "fop", ...).
    def account_type_for(snapshot, kind:)
      return JAR_KIND if kind == JAR_KIND

      snapshot[:type].presence
    end

    # Monobank gives jars a title but leaves cards unnamed, so a card is labelled by its
    # localized product name plus the last four digits when a masked PAN is present.
    def display_name_for(snapshot, kind:)
      if kind == JAR_KIND
        return snapshot[:title].presence || I18n.t("monobank_account.jar_fallback")
      end

      label = card_type_label(snapshot[:type])
      last_four = Array(snapshot[:maskedPan]).first.to_s[-4..]

      last_four.present? ? "#{label} ·#{last_four}" : label
    end

    # Localized product name for a card type, falling back to the raw value so an
    # unmapped new product still shows something recognizable.
    def card_type_label(type)
      key = type.to_s.downcase.presence || "unknown"

      I18n.t(
        "monobank_account.card_types.#{key}",
        default: I18n.t("monobank_account.card_types.unknown")
      )
    end

    # Monobank sends integer minor units; be tolerant of strings and nils.
    def to_decimal(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    # CurrencyNormalizable hook: warn when a Monobank currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Monobank account #{id}, defaulting to UAH")
    end
end
