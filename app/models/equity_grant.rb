# A stock award (RSUs or options) with its vesting schedule, on an Investment
# account of the "stock_plan" subtype.
#
# Grants are tracked alongside the account, not as holdings: vests don't create
# lots, so they don't change the account's balance or net worth.
class EquityGrant < ApplicationRecord
  include Monetizable

  GRANT_TYPES = %w[rsu option].freeze
  SOURCES = %w[manual csv statement].freeze

  belongs_to :account
  belongs_to :account_statement, optional: true
  belongs_to :security, optional: true
  has_many :vests, -> { order(:vest_date) }, class_name: "EquityVest", dependent: :destroy, inverse_of: :equity_grant

  enum :grant_type, GRANT_TYPES.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), validate: true, prefix: :from

  before_validation :normalize

  validates :ticker, presence: true, length: { maximum: 20 }
  validates :grant_identifier, length: { maximum: 100 }, uniqueness: { scope: :account_id }, allow_nil: true
  validates :notes, length: { maximum: 500 }
  validates :total_units, numericality: { greater_than: 0 }, allow_nil: true
  validates :strike_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :account_is_a_stock_plan

  # The ticker's security is looked up when the ticker changes, in the
  # background, so rendering a grant never calls a price provider.
  after_commit :resolve_security_later, if: -> { saved_change_to_ticker? || (security_id.nil? && previously_new_record?) }

  scope :ordered, -> { order(Arel.sql("grant_date IS NULL, grant_date"), :created_at) }

  def label
    [ grant_identifier.presence, grant_date && I18n.l(grant_date, format: :long) ].compact.join(" · ").presence || ticker
  end

  def forfeited?(as_of: Date.current)
    forfeited_on.present? && forfeited_on <= as_of
  end

  # Vests count as vested once their date has passed, unless they fall after
  # the grant was forfeited.
  def vested_units(as_of: Date.current)
    vests.select { |v| v.vested?(as_of: as_of) }.sum(&:units)
  end

  def unvested_units(as_of: Date.current)
    return 0 if forfeited?(as_of: as_of)

    scheduled = vests.reject { |v| v.vest_date <= as_of }.sum(&:units)
    return scheduled if total_units.blank?

    # Units granted but not yet scheduled are still outstanding.
    [ total_units - vested_units(as_of: as_of), scheduled ].max
  end

  # The latest stored price of the grant's security. Nil until the security has
  # been resolved and priced.
  def latest_price
    return @latest_price if defined?(@latest_price)

    price = security&.prices&.order(date: :desc)&.first
    @latest_price = price && Money.new(price.price, price.currency)
  end

  # What one unit is worth today: the share price for RSUs, the amount above
  # the strike for options (never negative). Nil for an option without a
  # strike, since its value can't be known.
  def unit_value
    return nil if latest_price.nil?
    return latest_price if rsu?
    return nil if strike_price.nil?

    strike = Money.new(strike_price, latest_price.currency)
    latest_price > strike ? latest_price - strike : Money.new(0, latest_price.currency)
  end

  def unvested_value(as_of: Date.current)
    unit_value && unit_value * unvested_units(as_of: as_of)
  end

  def resolve_security!
    resolved = Security::Resolver.new(ticker).resolve
    update_columns(security_id: resolved&.id, updated_at: Time.current)
    resolved&.find_or_fetch_price
    resolved
  end

  private
    def normalize
      self.ticker = ticker.to_s.strip.upcase.presence
      self.grant_identifier = grant_identifier.to_s.strip.presence
      self.notes = notes.to_s.strip.presence
    end

    def account_is_a_stock_plan
      errors.add(:account, :not_a_stock_plan) unless account&.investment&.stock_plan?
    end

    def resolve_security_later
      EquityGrantSecurityJob.perform_later(self)
    end
end
