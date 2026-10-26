class GiftCard < ApplicationRecord
  include Accountable, Encryptable

  CARD_FORMATS = %w[physical digital].freeze

  # How far ahead a card counts as "expiring soon" on its overview.
  EXPIRING_SOON_WINDOW = 30.days

  # The code, PIN and redeem link are what spends the card (a redeem link
  # often carries its own token), so they are kept out of serialized output:
  # the family data export and anything else that calls `as_json` on the
  # accountable.
  SENSITIVE_ATTRIBUTES = %w[card_number pin redeem_url].freeze

  # What a family data import restores. The credentials are never exported,
  # so they are not restored either.
  IMPORTABLE_ATTRIBUTES = %w[card_format expires_on face_value face_value_currency].freeze

  # Account permissions that may see the credentials: the ones that can act
  # on the account. A read-write share only annotates transactions, and a
  # read-only share only views; both see the balance and expiry, not the
  # means to redeem the card.
  CREDENTIAL_PERMISSIONS = %i[owner full_control].freeze

  if encryption_ready?
    encrypts :card_number
    encrypts :pin
    encrypts :redeem_url
  end

  normalizes :card_number, :pin, :redeem_url, with: ->(value) { value.strip.presence }

  validates :card_format, inclusion: { in: CARD_FORMATS }
  validates :redeem_url, format: { with: /\Ahttps?:\/\/\S+\z/i }, allow_nil: true
  validates :face_value, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :face_value_not_cleared

  before_validation :default_face_value_currency

  def physical?
    card_format == "physical"
  end

  def digital?
    card_format == "digital"
  end

  def expired?(as_of: Date.current)
    expires_on.present? && expires_on < as_of
  end

  def expiring_soon?(as_of: Date.current)
    expires_on.present? && !expired?(as_of: as_of) && expires_on <= as_of + EXPIRING_SOON_WINDOW
  end

  def days_until_expiry(as_of: Date.current)
    (expires_on - as_of).to_i if expires_on.present?
  end

  # The value the card was received or bought with, in the currency it was
  # issued in. Stored rather than read from the opening valuation, because
  # editing a manual cash account's balance rewrites that valuation. Nil when
  # unknown (a card imported without one).
  def initial_amount
    Money.new(face_value, face_value_currency) if face_value && face_value_currency
  end

  # Only while the card is still kept in the currency it was issued in. After
  # a change of the account's currency the balance is converted at the rates
  # of the sync, and comparing it with the face value would show exchange-rate
  # differences as spending.
  def spent_amount
    initial_amount - account.balance_money if initial_amount && face_value_currency == account.currency
  end

  def credentials_visible_to?(user)
    account.permission_for(user).in?(CREDENTIAL_PERMISSIONS)
  end

  # The code and PIN the user may see, keyed by attribute, without blanks.
  def visible_codes_for(user)
    return {} unless credentials_visible_to?(user)

    { card_number: card_number, pin: pin }.compact
  end

  def visible_redeem_url_for(user)
    redeem_url if credentials_visible_to?(user)
  end

  # Removed from the result rather than passed as `except`, which an explicit
  # `only` would override.
  def serializable_hash(options = nil)
    super.except(*SENSITIVE_ATTRIBUTES)
  end

  class << self
    def color
      "#F79009"
    end

    def icon
      "gift"
    end

    def classification
      "asset"
    end
  end

  private
    # A card created through its form gets the currency it was entered in. The
    # accountable is saved before its account, so this covers later edits: a
    # face value first entered then is in the account's current currency.
    #
    # The amount is kept at that currency's precision. The form doesn't round
    # it (it may be rendered in another currency), but shows it at this
    # precision, so saving the form again must not change it.
    def default_face_value_currency
      self.face_value_currency ||= account&.currency if face_value
      self.face_value = face_value.round(Money::Currency.new(face_value_currency).default_precision) if face_value && face_value_currency
    rescue Money::Currency::UnknownCurrencyError
      # An unknown currency code leaves the amount as entered.
    end

    # Once known, the initial amount is what "spent" is measured against;
    # clearing it would silently report nothing spent.
    def face_value_not_cleared
      errors.add(:face_value, :blank) if face_value.nil? && face_value_in_database.present?
    end
end
