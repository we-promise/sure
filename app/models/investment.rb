class Investment < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "brokerage" => { short: "Brokerage", long: "Brokerage" },
    "pension" => { short: "Pension", long: "Pension" },
    "retirement" => { short: "Retirement", long: "Retirement" },
    "401k" => { short: "401(k)", long: "401(k)" },
    "roth_401k" => { short: "Roth 401(k)", long: "Roth 401(k)" },
    "403b" => { short: "403(b)", long: "403(b)" },
    "457b" => { short: "457(b)", long: "457(b)" },
    "tsp" => { short: "TSP", long: "Thrift Savings Plan" },
    "529_plan" => { short: "529 Plan", long: "529 Plan" },
    "hsa" => { short: "HSA", long: "Health Savings Account" },
    "mutual_fund" => { short: "Mutual Fund", long: "Mutual Fund" },
    "ira" => { short: "IRA", long: "Traditional IRA" },
    "roth_ira" => { short: "Roth IRA", long: "Roth IRA" },
    "sep_ira" => { short: "SEP IRA", long: "SEP IRA" },
    "simple_ira" => { short: "SIMPLE IRA", long: "SIMPLE IRA" },
    "angel" => { short: "Angel", long: "Angel" },
    "trust" => { short: "Trust", long: "Trust" },
    "ugma" => { short: "UGMA", long: "UGMA" },
    "utma" => { short: "UTMA", long: "UTMA" },
    "other" => { short: "Other", long: "Other Investment" }
  }.freeze

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
  end
end
