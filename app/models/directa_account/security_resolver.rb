class DirectaAccount::SecurityResolver
  OFFLINE_REASON = "directa_isin".freeze

  def resolve(position)
    exact_security(position.isin, position.mic) || create_security(position)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    exact_security(position.isin, position.mic) ||
      raise(DirectaItem::PortfolioNormalizer::Error.new(:security_conflict), cause: nil)
  end

  private

    def create_security(position)
      Security.transaction(requires_new: true) do
        Security.create!(
          ticker: position.isin,
          exchange_operating_mic: position.mic,
          name: position.name,
          offline: true,
          offline_reason: OFFLINE_REASON
        )
      end
    end

    def exact_security(isin, mic)
      Security
        .where("UPPER(ticker) = ?", isin.to_s.upcase)
        .where("UPPER(exchange_operating_mic) = ?", mic.to_s.upcase)
        .first
    end
end
