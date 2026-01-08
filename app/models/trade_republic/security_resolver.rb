# Centralise la logique de résolution/association/creation de Security pour TradeRepublic
class TradeRepublic::SecurityResolver
  def initialize(isin, name: nil, ticker: nil, mic: nil)
    @isin = isin&.strip&.upcase
    @name = name
    @ticker = ticker
    @mic = mic
  end

  # Retourne la security existante ou la crée si besoin
  def resolve
    Rails.logger.info "Traderepublic::SecurityResolver - Resolve called: ISIN=#{@isin.inspect}, name=#{@name.inspect}, ticker=#{@ticker.inspect}, mic=#{@mic.inspect}"
    return nil unless @isin.present?

    # Recherche d'un match exact de l'ISIN dans le name
    security = Security.where("name LIKE ?", "%#{@isin}%").first
    if security
      Rails.logger.info "Traderepublic::SecurityResolver - Security trouvée par ISIN dans le name: id=#{security.id}, ISIN=#{@isin}, name=#{security.name.inspect}, ticker=#{security.ticker.inspect}, mic=#{security.exchange_operating_mic.inspect}"
      return security
    end

    # Création si aucune security trouvée
    name = @name.present? ? @name : "Security #{@isin}"
    name = "#{name} (#{@isin})" unless name.include?(@isin)
    begin
      security = Security.create!(name: name, ticker: @ticker, exchange_operating_mic: @mic)
      Rails.logger.info "Traderepublic::SecurityResolver - Security créée: id=#{security.id}, ISIN=#{@isin}, ticker=#{@ticker}, mic=#{@mic}, name=#{name.inspect}"
      security
    rescue ActiveRecord::RecordInvalid => e
      if e.message.include?("Ticker has already been taken")
        existing = Security.where(ticker: @ticker, exchange_operating_mic: @mic).first
        Rails.logger.warn "Traderepublic::SecurityResolver - Doublon ticker/mic, retourne l'existante: id=#{existing&.id}, ticker=#{@ticker}, mic=#{@mic}"
        return existing if existing
      end
      raise
    end
  end
end
