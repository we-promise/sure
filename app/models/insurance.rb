class Insurance < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "life" => { short: "Life", long: "Life Insurance" },
    "health" => { short: "Health", long: "Health Insurance" },
    "disability" => { short: "Disability", long: "Disability Insurance" },
    "long_term_care" => { short: "Long-term Care", long: "Long-term Care Insurance" },
    "homeowners" => { short: "Homeowners", long: "Homeowners Insurance" },
    "renters" => { short: "Renters", long: "Renters Insurance" },
    "auto" => { short: "Auto", long: "Auto Insurance" },
    "umbrella" => { short: "Umbrella", long: "Umbrella Insurance" },
    "travel" => { short: "Travel", long: "Travel Insurance" },
    "pet" => { short: "Pet", long: "Pet Insurance" },
    "other" => { short: "Other", long: "Other Insurance" }
  }.freeze

  PREMIUM_FREQUENCIES = %w[monthly quarterly semi_annual annual one_time other].freeze
  POLICY_ATTRIBUTES = %i[
    subtype policy_number coverage_amount premium_amount premium_frequency
    effective_date expiration_date renewal_date insured_name beneficiaries
  ].freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :premium_frequency, inclusion: { in: PREMIUM_FREQUENCIES }, allow_blank: true
  validates :coverage_amount, :premium_amount,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :expiration_date_follows_effective_date

  def policy_status(on: Date.current)
    return :upcoming if effective_date.present? && effective_date > on
    return :expired if expiration_date.present? && expiration_date < on
    return :renewal_due if renewal_date.present? && renewal_date.between?(on, on + 30.days)
    return :expiring_soon if expiration_date.present? && expiration_date.between?(on, on + 30.days)

    :active
  end

  def coverage_amount_money
    Money.new(coverage_amount, account.currency) if coverage_amount.present?
  end

  def premium_amount_money
    Money.new(premium_amount, account.currency) if premium_amount.present?
  end

  def balance_display_name
    "cash value"
  end

  def opening_balance_display_name
    "opening cash value"
  end

  class << self
    def color
      "#0284C7"
    end

    def icon
      "shield"
    end

    def classification
      "asset"
    end
  end

  private
    def expiration_date_follows_effective_date
      return if effective_date.blank? || expiration_date.blank?
      return if expiration_date >= effective_date

      errors.add(:expiration_date, :before_effective_date)
    end
end
