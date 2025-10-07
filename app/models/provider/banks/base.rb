class Provider::Banks::Base
  # Providers should implement:
  # - initialize(credentials = {})
  # - verify_credentials! -> true or raise
  # - list_accounts -> Array(provider_account_payload)
  # - list_transactions(account_id:, start_date:, end_date:) -> Array(provider_tx_payload)

  def initialize(credentials = {})
    @credentials = credentials.with_indifferent_access
  end

  def verify_credentials!
    raise NotImplementedError
  end

  def list_accounts
    raise NotImplementedError
  end

  def list_transactions(account_id:, start_date:, end_date:)
    raise NotImplementedError
  end
end

