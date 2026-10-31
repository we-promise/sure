class Security::Price < ApplicationRecord
  NORMALIZED_CURRENCY_SQL = "UPPER(BTRIM(security_prices.currency, CHR(9) || CHR(10) || CHR(11) || CHR(12) || CHR(13) || ' '))".freeze
  belongs_to :security

  validates :date, :price, :currency, presence: true
  validates :date, uniqueness: { scope: %i[security_id currency] }
  validate :currency_is_known

  before_validation :normalize_currency, if: -> { new_record? || will_save_change_to_currency? }
  before_save :settle_edited_retry_price

  scope :with_known_currency, -> { where(known_currency_predicate) }
  scope :in_currency, ->(code) { where("#{NORMALIZED_CURRENCY_SQL} = ?", normalized_currency(code)) }
  scope :with_unknown_currency, -> { where(known_currency_predicate.not.or(arel_table[:currency].eq(nil))) }
  scope :requiring_currency_retry, -> { where(currency_retry_required: true) }
  scope :with_unrecovered_currency, -> {
    with_unknown_currency.where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM (#{with_known_currency.where(currency_retry_required: false).select(:security_id, :date).to_sql}) recovered_prices
        WHERE recovered_prices.security_id = security_prices.security_id
          AND recovered_prices.date = security_prices.date
      )
    SQL
  }

  # Share currency classification without scanning IDs from all price history.
  def self.known_currency_predicate
    Arel.sql(NORMALIZED_CURRENCY_SQL).in(Money::Currency.all.keys.map(&:upcase))
  end

  # Return the normalized ISO code only when the currency registry recognizes it.
  def self.normalized_currency(code)
    Money::Currency.all[code.to_s.strip.downcase]&.fetch("iso_code")
  end

  # Safely read recognized legacy formatting without rewriting diagnostic data.
  def currency
    self.class.normalized_currency(self[:currency]) || self[:currency]
  end

  # Provisional prices from recent days that should be re-fetched
  # - Must be provisional (gap-filled)
  # - Must be from the last few days (configurable, default 7)
  # - Includes weekends: they get fixed via cascade when weekday prices are fetched
  scope :refetchable_provisional, ->(lookback_days: 7) {
    where(provisional: true)
      .where(date: lookback_days.days.ago.to_date..Date.current)
  }

  private
    # Validated edits supersede generated retry fallbacks. Provider bulk imports
    # bypass this callback and keep their own recovery/provisional decisions.
    def settle_edited_retry_price
      return unless persisted? && currency_retry_required?
      return unless will_save_change_to_price? || will_save_change_to_currency?

      self.currency_retry_required = false
      self.currency_retry_generated = false
      self.provisional = false
    end

    # Normalize recognized codes while leaving rejected input available to validation.
    def normalize_currency
      self.currency = currency.to_s.strip.upcase if currency.present?
    end

    # Reject unknown currencies before they can enter shared price history.
    def currency_is_known
      errors.add(:currency, :invalid) if currency.present? && self.class.normalized_currency(currency).nil?
    end
end
