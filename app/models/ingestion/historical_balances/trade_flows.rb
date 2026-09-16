# Every account trade affects equity performance, including manual and protected
# trades. Resolve missing FX before the writer's transaction and capture the
# actual dated rate; applying the command cannot silently fetch a different rate.
class Ingestion::HistoricalBalances::TradeFlows
  def initialize(inputs:, currency:, rate_resolver:)
    @inputs, @currency, @rate_resolver = inputs, currency, rate_resolver
  end

  def capture
    if ApplicationRecord.connection.open_transactions.positive?
      raise Provider::AccountData::InvalidResponse, "Historical FX collection must run outside a transaction"
    end
    trades = @inputs.fetch("trades").index_by { |trade| trade.fetch("id") }
    flows = Hash.new { |hash, key| hash[key] = BigDecimal("0") }
    failed, evidence = [], []
    @inputs.fetch("entries").each do |entry|
      next unless entry.fetch("entryable_type") == "Trade"
      trade = trades.fetch(entry.fetch("entryable_id"))
      next if trade.fetch("qty").zero?
      raw = trade.fetch("extra", {}).to_h["exchange_rate"]
      rate, date, origin = conversion(entry, raw)
      evidence << { "entry_id" => entry.fetch("id"), "from" => entry.fetch("currency"), "to" => @currency,
        "entry_date" => entry.fetch("date"), "rate" => rate, "rate_date" => date, "origin" => origin, "stored_rate" => raw }
      if rate
        flows[entry.fetch("date")] += entry.fetch("amount") * rate
      else
        failed << entry.fetch("date")
      end
    end
    { flows: flows, failed_dates: failed.uniq.sort, evidence: evidence }
  end

  private
    def conversion(entry, custom)
      return [ BigDecimal("1"), entry.fetch("date"), "same_currency" ] if entry.fetch("currency") == @currency
      if custom.present?
        # Trade#exchange_rate historically stores a Float. This explicit legacy
        # conversion matches Money#exchange_to; fresh API rates remain decimals.
        rate = stored_rate(custom)
        return [ rate&.finite? && rate.positive? ? rate : nil, entry.fetch("date"), "stored_trade" ]
      end
      result = @rate_resolver.call(from: entry.fetch("currency"), to: @currency, date: entry.fetch("date"))
      return [ nil, nil, "unavailable" ] unless result
      unless result.is_a?(Hash) && result[:rate].is_a?(BigDecimal) && result[:rate].finite? && result[:rate].positive?
        raise Provider::AccountData::InvalidResponse, "Invalid historical exchange rate"
      end
      unless result[:date].is_a?(String) && result[:date].match?(/\A\d{4}-\d{2}-\d{2}\z/)
        raise Provider::AccountData::InvalidResponse, "Invalid historical exchange-rate date"
      end
      rate_date = Date.iso8601(result.fetch(:date))
      raise Provider::AccountData::InvalidResponse, "Historical exchange rate is from the future" if rate_date > entry.fetch("date")
      [ result.fetch(:rate), rate_date, "market" ]
    end

    def stored_rate(value)
      value.is_a?(Float) ? (value.finite? ? value.to_d : nil) : BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
end
