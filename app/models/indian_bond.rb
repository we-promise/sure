class IndianBond < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "govt_securities" => { short: "G-Sec", long: "Government Securities (G-Sec)", region: "in", tax_treatment: :taxable },
    "state_development_loans" => { short: "SDL", long: "State Development Loans", region: "in", tax_treatment: :taxable },
    "corporate_bonds" => { short: "Corp Bond", long: "Corporate Bonds", region: "in", tax_treatment: :taxable },
    "psu_bonds" => { short: "PSU Bond", long: "PSU Bonds", region: "in", tax_treatment: :taxable },
    "infrastructure_bonds" => { short: "Infra Bond", long: "Infrastructure Bonds (Section 54EC)", region: "in", tax_treatment: :tax_advantaged },
    "capital_gains_bonds" => { short: "54EC Bond", long: "Capital Gains Bonds (Section 54EC)", region: "in", tax_treatment: :tax_exempt },
    "tax_free_bonds" => { short: "Tax-Free", long: "Tax-Free Bonds", region: "in", tax_treatment: :tax_exempt },
    "ncd" => { short: "NCD", long: "Non-Convertible Debentures", region: "in", tax_treatment: :taxable },
    "debentures" => { short: "Debenture", long: "Debentures", region: "in", tax_treatment: :taxable },
    "commercial_paper" => { short: "CP", long: "Commercial Paper", region: "in", tax_treatment: :taxable }
  }.freeze

  attribute :face_value, :decimal, precision: 19, scale: 4
  attribute :coupon_rate, :decimal, precision: 5, scale: 2
  attribute :maturity_date, :date
  attribute :isin, :string
  attribute :rating, :string
  attribute :interest_frequency, :string, default: "quarterly"

  class << self
    def icon
      "file-text"
    end

    def color
      "#7C3AED"
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
    "face value"
  end

  def trend
    Trend.new(current: account.balance_money, previous: face_value || account.balance_money)
  end

  def coupon_rate_display
    "#{coupon_rate}%" if coupon_rate.present?
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

  def interest_frequency_display
    case interest_frequency
    when "monthly" then "Monthly"
    when "quarterly" then "Quarterly"
    when "semi_annually" then "Semi-Annually"
    when "annually" then "Annually"
    when "at_maturity" then "At Maturity"
    else interest_frequency.titleize
    end
  end
end
