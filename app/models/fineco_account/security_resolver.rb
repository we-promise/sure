class FinecoAccount::SecurityResolver
  OFFLINE_REASON = "fineco_isin".freeze

  def resolve(position)
    existing = exact_security(position.isin, position.mic)
    return existing if existing

    Security.transaction(requires_new: true) do
      Security.create!(
        ticker: position.isin,
        exchange_operating_mic: position.mic,
        name: position.name,
        offline: true,
        offline_reason: OFFLINE_REASON
      )
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    exact_security(position.isin, position.mic) ||
      raise(FinecoItem::PortfolioImportError.new(:security_conflict), cause: nil)
  end

  private

    def exact_security(isin, mic)
      Security.where("UPPER(ticker) = ?", isin).where("UPPER(exchange_operating_mic) = ?", mic).first
    end
end
