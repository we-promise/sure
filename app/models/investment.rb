class Investment < ApplicationRecord
  include Accountable

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
    "rrsp" => { short: "RRSP", long: "Registered Retirement Savings Plan", region: "ca", tax_treatment: :tax_deferred },
    "tfsa" => { short: "TFSA", long: "Tax-Free Savings Account", region: "ca", tax_treatment: :tax_exempt },
    "resp" => { short: "RESP", long: "Registered Education Savings Plan", region: "ca", tax_treatment: :tax_advantaged },
    "lira" => { short: "LIRA", long: "Locked-In Retirement Account", region: "ca", tax_treatment: :tax_deferred },
    "rrif" => { short: "RRIF", long: "Registered Retirement Income Fund", region: "ca", tax_treatment: :tax_deferred },

    # === Australia ===
    "super" => { short: "Super", long: "Superannuation", region: "au", tax_treatment: :tax_deferred },
    "smsf" => { short: "SMSF", long: "Self-Managed Super Fund", region: "au", tax_treatment: :tax_deferred },

    # === Europe ===
    "pillar_3a" => { short: "Pillar 3a", long: "Private Pension (Pillar 3a)", region: "eu", tax_treatment: :tax_deferred },
    "riester" => { short: "Riester", long: "Riester-Rente", region: "eu", tax_treatment: :tax_deferred },

    # === France ===
    "assurance_vie" => { short: "Assurance Vie", long: "Assurance Vie", region: "fr", tax_treatment: :tax_advantaged },
    "contrat_de_capitalisation" => { short: "Contrat de Capitalisation", long: "Contrat de Capitalisation", region: "fr", tax_treatment: :tax_advantaged },
    "cto" => { short: "CTO", long: "Compte-Titres Ordinaire", region: "fr", tax_treatment: :taxable },
    "livret_a" => { short: "Livret A", long: "Livret A", region: "fr", tax_treatment: :tax_exempt },
    "ldds" => { short: "LDDS", long: "Livret de Développement Durable et Solidaire", region: "fr", tax_treatment: :tax_exempt },
    "lee" => { short: "LEE", long: "Livret d'Épargne Entreprise", region: "fr", tax_treatment: :taxable },
    "lep" => { short: "LEP", long: "Livret d'Épargne Populaire", region: "fr", tax_treatment: :tax_exempt },
    "livret_jeune" => { short: "Livret Jeune", long: "Livret Jeune", region: "fr", tax_treatment: :tax_exempt },
    "pea" => { short: "PEA", long: "Plan d'Épargne en Actions", region: "fr", tax_treatment: :tax_advantaged },
    "pee" => { short: "PEE", long: "Plan d'Épargne Entreprise", region: "fr", tax_treatment: :tax_advantaged },
    "peg" => { short: "PEG", long: "Plan d'Épargne Groupe", region: "fr", tax_treatment: :tax_advantaged },
    "pel" => { short: "PEL", long: "Plan d'Épargne Logement", region: "fr", tax_treatment: :tax_advantaged },
    "per" => { short: "PER", long: "Plan d'Épargne Retraite", region: "fr", tax_treatment: :tax_deferred },
    "per_individuel" => { short: "PER Individuel", long: "Plan d'Épargne Retraite Individuel", region: "fr", tax_treatment: :tax_deferred },
    "per_collectif" => { short: "PER Collectif", long: "Plan d'Épargne Retraite Collectif", region: "fr", tax_treatment: :tax_deferred },
    "per_obligatoire" => { short: "PER Obligatoire", long: "Plan d'Épargne Retraite Obligatoire", region: "fr", tax_treatment: :tax_deferred },

    # === Generic (available everywhere) ===
    "pension" => { short: "Pension", long: "Pension", region: nil, tax_treatment: :tax_deferred },
    "retirement" => { short: "Retirement", long: "Retirement Account", region: nil, tax_treatment: :tax_deferred },
    "mutual_fund" => { short: "Mutual Fund", long: "Mutual Fund", region: nil, tax_treatment: :taxable },
    "angel" => { short: "Angel", long: "Angel Investment", region: nil, tax_treatment: :taxable },
    "trust" => { short: "Trust", long: "Trust", region: nil, tax_treatment: :taxable },
    "other" => { short: "Other", long: "Other Investment", region: nil, tax_treatment: :taxable }
  }.freeze

  def tax_treatment
    SUBTYPES.dig(subtype, :tax_treatment) || :taxable
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
      "CHF" => "eu"
    }.freeze

    # Returns subtypes grouped by region for use with grouped_options_for_select
    # Optionally accepts country (ISO 2-letter code) to prioritize user's country first, else currency
    # Region mappings are configured in config/regions.yml
    def subtypes_grouped_for_select(currency: nil, country: nil)
      # Prefer country if provided, else fallback to currency mapping
      user_region = Regions.region_for(country: country, currency: currency)
      grouped = SUBTYPES.group_by { |_, v| v[:region] }

      # Build region order: user's region first (if known), then Generic, then others
      other_regions = %w[us uk ca au eu fr] - [ user_region ].compact
      region_order = [ user_region, nil, *other_regions ].compact.uniq

      region_order.filter_map do |region|
        next unless grouped[region]
        [ region_label_for(region), grouped[region].map { |k, v| [ v[:long], k ] } ]
      end
    end
  end
end
