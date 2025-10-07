class Provider::Banks::Mapper
  # Normalize provider-native payloads into a common hash shape
  # Return hashes to keep it simple and avoid leaking provider objects

  # Expected account shape:
  # {
  #   provider_account_id: "...",
  #   name: "...",
  #   currency: "USD",
  #   current_balance: BigDecimal,
  #   available_balance: BigDecimal
  # }
  def normalize_account(_payload)
    raise NotImplementedError
  end

  # Expected transaction shape:
  # {
  #   external_id: "provider_specific_unique_id",
  #   posted_at: Date,
  #   amount: BigDecimal,
  #   description: "..."
  # }
  def normalize_transaction(_payload, currency:)
    raise NotImplementedError
  end
end

