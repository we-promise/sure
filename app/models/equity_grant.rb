# A stock award (RSUs or options) with its vesting schedule. Vests on or
# before today count as vested; later ones are upcoming and are valued at the
# latest known price of the grant's ticker.
class EquityGrant < ApplicationRecord
  GRANT_TYPES = %w[rsu option].freeze
  SOURCES = %w[manual csv statement].freeze

  belongs_to :account
  belongs_to :account_statement, optional: true
  has_many :vests, -> { order(:vest_date) }, class_name: "EquityVest", dependent: :destroy, inverse_of: :equity_grant

  enum :grant_type, GRANT_TYPES.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), validate: true, prefix: :from

  before_validation { self.ticker = ticker.to_s.strip.upcase.presence }

  validates :ticker, presence: true
  validates :grant_identifier, uniqueness: { scope: :account_id }, allow_blank: true
  validates :total_units, numericality: { greater_than: 0 }, allow_nil: true

  scope :ordered, -> { order(Arel.sql("grant_date IS NULL, grant_date"), :created_at) }

  def label
    [ grant_identifier.presence, grant_date && I18n.l(grant_date, format: :long) ].compact.join(" · ").presence || ticker
  end

  def vested_units(as_of: Date.current)
    vests.select { |v| v.vest_date <= as_of }.sum(&:units)
  end

  def unvested_units(as_of: Date.current)
    scheduled = vests.reject { |v| v.vest_date <= as_of }.sum(&:units)
    return scheduled if total_units.blank?

    # A grant whose remaining schedule hasn't been entered still has its
    # unscheduled units outstanding.
    [ total_units - vested_units(as_of: as_of), scheduled ].max
  end

  def security
    return @security if defined?(@security)

    @security = Security.where(ticker: ticker).order(Arel.sql("offline ASC, created_at ASC")).first
  end

  # Latest known share price: a stored price for the ticker when Sure tracks
  # it, otherwise a quote from the enabled price providers, cached for a few
  # hours so the page doesn't call a provider on every render.
  def latest_price
    return @latest_price if defined?(@latest_price)

    price = security&.prices&.order(date: :desc)&.first
    @latest_price = price ? Money.new(price.price, price.currency) : provider_price
  end

  def provider_price
    cached = Rails.cache.fetch("equity_grant_price/v1/#{ticker}", expires_in: 6.hours, skip_nil: true) do
      price = Security::Resolver.new(ticker).resolve&.find_or_fetch_price
      price && { "amount" => price.price.to_s, "currency" => price.currency }
    end
    cached && Money.new(BigDecimal(cached["amount"]), cached["currency"])
  rescue StandardError => e
    Rails.logger.warn("[EquityGrant] price lookup for #{ticker} failed: #{e.message}")
    nil
  end

  def unvested_value(as_of: Date.current)
    latest_price && latest_price * unvested_units(as_of: as_of)
  end
end
