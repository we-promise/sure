class ScalableAccount::SecurityResolver
  OFFLINE_REASON = "scalable_isin".freeze

  def resolve(position)
    existing = exact_security(position.isin)
    return existing if existing

    Security.transaction(requires_new: true) do
      security = Security.find_or_initialize_by_ticker_and_exchange(
        ticker: position.isin,
        exchange_operating_mic: nil
      )
      if security.new_record?
        security.assign_attributes(
          name: position.name,
          offline: true,
          offline_reason: OFFLINE_REASON
        )
      end
      security.save!
      security
    end
  rescue Provider::Scalable::Error
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    exact_security(position.isin) || raise(Provider::Scalable::Error.new(:account_conflict), cause: nil)
  rescue ActiveRecord::RecordNotFound
    raise Provider::Scalable::Error.new(:account_conflict), cause: nil
  end

  private

    def exact_security(isin)
      Security.find_by_ticker_and_exchange(
        ticker: isin.to_s.upcase,
        exchange_operating_mic: nil,
        match_blank_mic: true
      )
    end
end
