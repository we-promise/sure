class ExchangeRate < ApplicationRecord
  include Provided

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }

  # Builds a LEFT JOIN LATERAL fragment that resolves the nearest known rate
  # for converting +currency+ into the surrounding query's :target_currency
  # param at +date+: the most recent rate on or before the date, otherwise the
  # first rate after it. `#{table_alias}.rate` is NULL only when the pair has
  # no rates at all, so callers COALESCE to 1 as a last resort instead of
  # silently converting at 1.0 whenever the exact date is missing.
  #
  # +currency+ and +date+ are SQL column expressions supplied by the caller
  # (e.g. "ae.currency"), never user input.
  def self.nearest_rate_join_sql(currency:, date:, table_alias: "er")
    <<~SQL
      LEFT JOIN LATERAL (
        SELECT COALESCE(
          (SELECT er.rate
           FROM exchange_rates er
           WHERE er.from_currency = #{currency}
             AND er.to_currency = :target_currency
             AND er.date <= #{date}
           ORDER BY er.date DESC
           LIMIT 1),
          (SELECT er.rate
           FROM exchange_rates er
           WHERE er.from_currency = #{currency}
             AND er.to_currency = :target_currency
             AND er.date > #{date}
           ORDER BY er.date ASC
           LIMIT 1)
        ) AS rate
      ) #{table_alias} ON TRUE
    SQL
  end
end
