class Investment < ApplicationRecord
  include Accountable

  GOLD_WEIGHT_UNITS = %w[gram troy_ounce kilogram].freeze
  GOLD_FORMS = %w[physical digital].freeze
  MAX_GOLD_KARAT = BigDecimal("24")

  # Tax treatment categories:
  # - taxable: Gains taxed when realized
  # - tax_deferred: Taxes deferred until withdrawal
  # - tax_exempt: Qualified gains are tax-free
  # - tax_advantaged: Special tax benefits with conditions
  SUBTYPES = {
    # === United States ===
    "brokerage" => { short: "Brokerage", long: "Brokerage", region: "us", tax_treatment: :taxable },
    "401k" => { short: "401(k)", long: "401(k)", region: "us", tax_treatment: :tax_deferred },
    "roth_401k" => { short: "Roth 401(k)", long: "Roth 401(k)", region: "us", tax_treatment: :tax_exempt },
    "403b" => { short: "403(b)", long: "403(b)", region: "us", tax_treatment: :tax_deferred },
    "457b" => { short: "457(b)", long: "457(b)", region: "us", tax_treatment: :tax_deferred },
    "tsp" => { short: "TSP", long: "Thrift Savings Plan", region: "us", tax_treatment: :tax_deferred },
    "ira" => { short: "IRA", long: "Traditional IRA", region: "us", tax_treatment: :tax_deferred },
    "roth_ira" => { short: "Roth IRA", long: "Roth IRA", region: "us", tax_treatment: :tax_exempt },
    "sep_ira" => { short: "SEP IRA", long: "SEP IRA", region: "us", tax_treatment: :tax_deferred },
    "simple_ira" => { short: "SIMPLE IRA", long: "SIMPLE IRA", region: "us", tax_treatment: :tax_deferred },
    "529_plan" => { short: "529 Plan", long: "529 Education Savings Plan", region: "us", tax_treatment: :tax_advantaged },
    "hsa" => { short: "HSA", long: "Health Savings Account", region: "us", tax_treatment: :tax_advantaged },
    "ugma" => { short: "UGMA", long: "UGMA Custodial Account", region: "us", tax_treatment: :taxable },
    "utma" => { short: "UTMA", long: "UTMA Custodial Account", region: "us", tax_treatment: :taxable },

    # === United Kingdom ===
    "isa" => { short: "ISA", long: "Individual Savings Account", region: "uk", tax_treatment: :tax_exempt },
    "lisa" => { short: "LISA", long: "Lifetime ISA", region: "uk", tax_treatment: :tax_exempt },
    "sipp" => { short: "SIPP", long: "Self-Invested Personal Pension", region: "uk", tax_treatment: :tax_deferred },
    "workplace_pension_uk" => { short: "Pension", long: "Workplace Pension", region: "uk", tax_treatment: :tax_deferred },

    # === Canada ===
    "tfsa" => { short: "TFSA", long: "Tax-Free Savings Account", region: "ca", tax_treatment: :tax_exempt },
    "rrsp" => { short: "RRSP", long: "Registered Retirement Savings Plan", region: "ca", tax_treatment: :tax_deferred },
    "non-registered" => { short: "Non-Registered", long: "Non-Registered Investment Account", region: "ca", tax_treatment: :taxable },
    "fhsa" => { short: "FHSA", long: "First Home Savings Account", region: "ca", tax_treatment: :tax_exempt },
    "rdsp" => { short: "RDSP", long: "Registered Disability Savings Plan", region: "ca", tax_treatment: :tax_advantaged },
    "resp" => { short: "RESP", long: "Registered Education Savings Plan", region: "ca", tax_treatment: :tax_advantaged },
    "dpsp" => { short: "DPSP", long: "Deferred Profit Sharing Plan", region: "ca", tax_treatment: :tax_deferred },
    "prpp" => { short: "PRPP", long: "Pooled Registered Pension Plan", region: "ca", tax_treatment: :tax_deferred },
    "lira" => { short: "LIRA", long: "Locked-In Retirement Account", region: "ca", tax_treatment: :tax_deferred },
    "rrif" => { short: "RRIF", long: "Registered Retirement Income Fund", region: "ca", tax_treatment: :tax_deferred },
    "lif" => { short: "LIF", long: "Life Income Fund", region: "ca", tax_treatment: :tax_deferred },
    "lrif" => { short: "LRIF", long: "Locked-In Retirement Income Fund", region: "ca", tax_treatment: :tax_deferred },
    "prif" => { short: "PRIF", long: "Prescribed Registered Retirement Income Fund", region: "ca", tax_treatment: :tax_deferred },
    "rlif" => { short: "RLIF", long: "Restricted Life Income Fund", region: "ca", tax_treatment: :tax_deferred },

    # === Australia ===
    "super" => { short: "Super", long: "Superannuation", region: "au", tax_treatment: :tax_deferred },
    "smsf" => { short: "SMSF", long: "Self-Managed Super Fund", region: "au", tax_treatment: :tax_deferred },

    # === Europe ===
    "assurance_vie" => { short: "AV", long: "Assurance Vie", region: "eu", tax_treatment: :tax_advantaged },
    "pea" => { short: "PEA", long: "Plan d'Épargne en Actions", region: "eu", tax_treatment: :tax_advantaged },
    "pillar_3a" => { short: "Pillar 3a", long: "Private Pension (Pillar 3a)", region: "eu", tax_treatment: :tax_deferred },
    "riester" => { short: "Riester", long: "Riester-Rente", region: "eu", tax_treatment: :tax_deferred },

    # === India ===
    # Pensions & insurance
    "nps" => { short: "NPS", long: "National Pension System", region: "in", tax_treatment: :tax_advantaged },
    "apy" => { short: "APY", long: "Atal Pension Yojana", region: "in", tax_treatment: :tax_advantaged },
    "life_insurance" => { short: "Life Insurance", long: "Life Insurance", region: "in", tax_treatment: :tax_advantaged },
    # Equity / market-linked
    "indian_stocks" => { short: "Indian Stocks", long: "Indian Stocks (Demat)", region: "in", tax_treatment: :taxable },
    "indian_equity" => { short: "Indian Equity", long: "Indian Equity", region: "in", tax_treatment: :taxable },
    "indian_etf" => { short: "Indian ETF", long: "Indian ETF", region: "in", tax_treatment: :taxable },
    # Fixed-income / small-savings
    "ppf" => { short: "PPF", long: "Public Provident Fund", region: "in", tax_treatment: :tax_exempt },
    "ssy" => { short: "SSY", long: "Sukanya Samriddhi Yojana", region: "in", tax_treatment: :tax_exempt },
    "nsc" => { short: "NSC", long: "National Savings Certificate", region: "in", tax_treatment: :tax_advantaged },
    "scss" => { short: "SCSS", long: "Senior Citizens' Savings Scheme", region: "in", tax_treatment: :taxable },
    "fd" => { short: "FD", long: "Fixed Deposit", region: "in", tax_treatment: :taxable },
    "rd" => { short: "RD", long: "Recurring Deposit", region: "in", tax_treatment: :taxable },
    "pomis" => { short: "POMIS", long: "Post Office Monthly Income Scheme", region: "in", tax_treatment: :taxable },
    "kvp" => { short: "KVP", long: "Kisan Vikas Patra", region: "in", tax_treatment: :taxable },
    # Bonds
    "g_sec" => { short: "G-Sec", long: "Government Securities (G-Secs)", region: "in", tax_treatment: :taxable },
    "sdl" => { short: "SDL", long: "State Development Loans (SDLs)", region: "in", tax_treatment: :taxable },
    "corporate_bond" => { short: "Corporate Bond", long: "Corporate Bond", region: "in", tax_treatment: :taxable },
    "infrastructure_bond" => { short: "Infra Bond", long: "Infrastructure Bond", region: "in", tax_treatment: :tax_advantaged },
    "tax_free_bond" => { short: "Tax-Free Bond", long: "Tax-Free Bond", region: "in", tax_treatment: :tax_exempt },
    # India-specific gold instruments
    "gold_etf" => { short: "Gold ETF", long: "Gold ETF", region: "in", tax_treatment: :taxable },
    "gold_mf" => { short: "Gold MF", long: "Gold Mutual Fund", region: "in", tax_treatment: :taxable },
    "sgb" => { short: "SGB", long: "Sovereign Gold Bond", region: "in", tax_treatment: :tax_advantaged },

    # === Generic (available everywhere) ===
    "pension" => { short: "Pension", long: "Pension", region: nil, tax_treatment: :tax_deferred },
    "retirement" => { short: "Retirement", long: "Retirement Account", region: nil, tax_treatment: :tax_deferred },
    "mutual_fund" => { short: "Mutual Fund", long: "Mutual Fund", region: nil, tax_treatment: :taxable },
    "gold" => { short: "Gold", long: "Gold (physical or digital)", region: nil, tax_treatment: :taxable },
    "angel" => { short: "Angel", long: "Angel Investment", region: nil, tax_treatment: :taxable },
    "trust" => { short: "Trust", long: "Trust", region: nil, tax_treatment: :taxable },
    "other" => { short: "Other", long: "Other Investment", region: nil, tax_treatment: :taxable }
  }.freeze

  def tax_treatment
    SUBTYPES.dig(subtype, :tax_treatment) || :taxable
  end

  validates :gold_weight, numericality: { greater_than: 0 }, allow_nil: true
  validates :gold_weight_unit, inclusion: { in: GOLD_WEIGHT_UNITS }, allow_nil: true
  validates :gold_karat, numericality: { greater_than: 0, less_than_or_equal_to: MAX_GOLD_KARAT }, allow_nil: true
  validates :gold_manual_value, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :gold_form, inclusion: { in: GOLD_FORMS }, allow_nil: true
  before_validation :default_gold_form
  before_validation :clear_physical_gold_details_for_digital_form
  validate :gold_form_only_for_gold_investments
  validate :physical_gold_details_only_for_physical_gold_investments
  validate :physical_gold_cannot_have_securities

  def gold?
    subtype == "gold"
  end

  def physical_gold?
    gold? && gold_form == "physical"
  end

  def digital_gold?
    gold? && gold_form == "digital"
  end

  def gold_details_complete?
    physical_gold_lots.any? || (gold_weight.present? && gold_weight_unit.present? && gold_karat.present?)
  end

  def physical_gold_lots
    account ? account.physical_gold_lots : PhysicalGoldLot.none
  end

  def gold_weight_in_grams
    return BigDecimal(0) unless gold_weight.present?

    case gold_weight_unit
    when "gram" then gold_weight.to_d
    when "kilogram" then gold_weight.to_d * 1_000
    when "troy_ounce" then gold_weight.to_d * GoldValuation::TROY_OUNCE_GRAMS
    else BigDecimal(0)
    end
  end

  # `price_per_troy_ounce` is the XAU quote; karat adjusts it to the item's
  # fine-gold content (for example, 18k is 75% of 24k spot value).
  def gold_value_for(price_per_troy_ounce)
    return physical_gold_lots.sum { |lot| lot.value_for(price_per_troy_ounce) } if physical_gold_lots.any?
    return gold_manual_value.to_d if gold_manual_value.present?

    gold_weight_in_grams * gold_karat.to_d / MAX_GOLD_KARAT * price_per_troy_ounce.to_d / GoldValuation::TROY_OUNCE_GRAMS
  end

  def gold_fine_weight_in_grams
    return physical_gold_lots.sum(&:fine_weight_in_grams) if physical_gold_lots.any?

    gold_weight_in_grams * gold_karat.to_d / MAX_GOLD_KARAT
  end

  def gold_total_weight_in_grams
    return physical_gold_lots.sum(&:weight_in_grams) if physical_gold_lots.any?

    gold_weight_in_grams
  end

  def latest_gold_rate
    return unless account

    ExchangeRate.where(from_currency: "XAU", to_currency: account.currency).order(date: :desc).first
  end

  def gold_spot_price_per_gram(rate: latest_gold_rate)
    rate&.rate&.to_d&./(GoldValuation::TROY_OUNCE_GRAMS)
  end

  def gold_spot_price_required?
    return physical_gold_lots.any? { |lot| !lot.manual_value? } if physical_gold_lots.any?

    gold_manual_value.blank?
  end

  private
    def default_gold_form
      self.gold_form = "physical" if gold? && gold_form.blank?
    end

    def clear_physical_gold_details_for_digital_form
      return unless digital_gold?

      self.gold_weight = nil
      self.gold_weight_unit = nil
      self.gold_karat = nil
      self.gold_manual_value = nil
    end

    def gold_form_only_for_gold_investments
      return if gold? || gold_form.blank?

      errors.add(:gold_form, I18n.t("investments.errors.gold_form_only_for_gold"))
    end

    def physical_gold_details_only_for_physical_gold_investments
      return if physical_gold? || [ gold_weight, gold_weight_unit, gold_karat, gold_manual_value ].all?(&:blank?)

      errors.add(:base, I18n.t("investments.errors.gold_details_only_for_gold"))
    end

    def physical_gold_cannot_have_securities
      return unless physical_gold? && account&.persisted? && account.holdings.exists?

      errors.add(:subtype, I18n.t("investments.errors.gold_cannot_have_holdings"))
    end

    class << self
      def color
        "#1570EF"
      end

      def classification
        "asset"
      end

      def icon
        "chart-line"
      end

      def region_label_for(region)
        I18n.t("accounts.subtype_regions.#{region || 'generic'}")
      end

      # Maps currency codes to regions for prioritizing user's likely region
      CURRENCY_REGION_MAP = {
        "USD" => "us",
        "GBP" => "uk",
        "CAD" => "ca",
        "AUD" => "au",
        "EUR" => "eu",
        "CHF" => "eu",
        "INR" => "in"
      }.freeze

      # Returns subtypes grouped by region for use with grouped_options_for_select
      # Optionally accepts currency to prioritize user's region first
      def subtypes_grouped_for_select(currency: nil)
        user_region = CURRENCY_REGION_MAP[currency]
        grouped = SUBTYPES.group_by { |_, v| v[:region] }

        # Build region order: user's region first (if known), then Generic, then others
        other_regions = %w[us uk ca au eu in] - [ user_region ].compact
        region_order = if user_region
          [ user_region, nil, *other_regions ].uniq
        else
          [ nil, *other_regions ].uniq
        end

        region_order.filter_map do |region|
          next unless grouped[region]
          [ region_label_for(region), grouped[region].map { |k, _v| [ long_subtype_label_for(k), k ] } ]
        end
      end
    end
end
