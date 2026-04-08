class IndianFixedInvestment < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "ppf" => { short: "PPF", long: "Public Provident Fund", region: "in", tax_treatment: :tax_exempt },
    "ssy" => { short: "SSY", long: "Sukanya Samriddhi Yojana", region: "in", tax_treatment: :tax_exempt },
    "nsc" => { short: "NSC", long: "National Savings Certificate", region: "in", tax_treatment: :tax_exempt },
    "scss" => { short: "SCSS", long: "Senior Citizens Savings Scheme", region: "in", tax_treatment: :taxable },
    "fd" => { short: "Bank FD", long: "Fixed Deposit", region: "in", tax_treatment: :taxable },
    "rd" => { short: "Recurring Deposit", long: "Recurring Deposit", region: "in", tax_treatment: :taxable },
    "pomis" => { short: "POMIS", long: "Post Office Monthly Income Scheme", region: "in", tax_treatment: :taxable },
    "kisan_vikas_patra" => { short: "KVP", long: "Kisan Vikas Patra", region: "in", tax_treatment: :taxable },
    "sukanya_samriddhi_2" => { short: "SSY 2", long: "Sukanya Samriddhi Yojana 2", region: "in", tax_treatment: :tax_exempt },
    "mahila_samman_savings" => { short: "MSS", long: "Mahila Samman Savings Certificate", region: "in", tax_treatment: :taxable }
  }.freeze

  attribute :interest_rate, :decimal, precision: 5, scale: 2
  attribute :maturity_date, :date
  attribute :deposit_amount, :decimal, precision: 19, scale: 4
  attribute :deposit_frequency, :string, default: "monthly"

  class << self
    def icon
      "landmark"
    end

    def color
      "#875BF7"
    end

    def classification
      "asset"
    end

    def region_label_for(region)
      I18n.t("accounts.subtype_regions.#{region || 'generic'}")
    end

    def subtypes_grouped_for_select(currency: nil)
      grouped = SUBTYPES.group_by { |_, v| v[:region] }
      region_label = region_label_for("in")
      [ [ region_label, SUBTYPES.map { |k, v| [ v[:long], k ] } ] ]
    end
  end

  def tax_treatment
    SUBTYPES.dig(subtype, :tax_treatment) || :taxable
  end

  def balance_display_name
    "current value"
  end

  def opening_balance_display_name
    "deposit amount"
  end

  def trend
    Trend.new(current: account.balance_money, previous: deposit_amount || account.balance_money)
  end

  def interest_rate_display
    "#{interest_rate}%" if interest_rate.present?
  end

  def days_to_maturity
    return nil unless maturity_date.present?
    (maturity_date - Date.current).to_i
  end

  def maturity_status
    days = days_to_maturity
    return "Matured" if days.present? && days <= 0
    return "Maturing Soon" if days.present? && days <= 90
    "Active"
  end
end
