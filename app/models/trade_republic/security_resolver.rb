
# Centralizes logic for resolving, associating, or creating a Security for TradeRepublic
class TradeRepublic::SecurityResolver
  def initialize(isin, name: nil, ticker: nil, mic: nil)
    @isin = isin&.strip&.upcase
    @name = name
    @ticker = ticker
    @mic = mic
  end

  # Returns the existing Security or creates a new one if not found
  def resolve
    Rails.logger.info "TradeRepublic::SecurityResolver - Resolve called: ISIN=#{@isin.inspect}, name=#{@name.inspect}, ticker=#{@ticker.inspect}, mic=#{@mic.inspect}"
    return nil unless @isin.present?

    # Search for an exact ISIN match in the name
    security = Security.where("name LIKE ?", "%#{@isin}%").first
    if security
      Rails.logger.info "TradeRepublic::SecurityResolver - Security found by ISIN in name: id=#{security.id}, ISIN=#{@isin}, name=#{security.name.inspect}, ticker=#{security.ticker.inspect}, mic=#{security.exchange_operating_mic.inspect}"
      return security
    end

    # Create a new Security if none found
    name = @name.present? ? @name : "Security #{@isin}"
    name = "#{name} (#{@isin})" unless name.include?(@isin)
    begin
      security = Security.create!(name: name, ticker: @ticker, exchange_operating_mic: @mic)
      Rails.logger.info "TradeRepublic::SecurityResolver - Security created: id=#{security.id}, ISIN=#{@isin}, ticker=#{@ticker}, mic=#{@mic}, name=#{name.inspect}"
      security
    rescue ActiveRecord::RecordInvalid => e
      if e.message.include?("Ticker has already been taken")
        existing = Security.where(ticker: @ticker, exchange_operating_mic: @mic).first
        Rails.logger.warn "TradeRepublic::SecurityResolver - Duplicate ticker/mic, returning existing: id=#{existing&.id}, ticker=#{@ticker}, mic=#{@mic}"
        return existing if existing
      end
      raise
    end
  end
end
