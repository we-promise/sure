module BankProviders
  class Base
    # Lists available accounts for the authenticated connection.
    # Should return an array of hashes normalized for the application.
    def list_accounts
      raise NotImplementedError, "Subclasses must implement #list_accounts"
    end

    # Fetches transactions for a given account.
    # Expected to return an array of normalized transaction hashes.
    def fetch_transactions(account_id, from: nil, to: nil)
      raise NotImplementedError, "Subclasses must implement #fetch_transactions"
    end
  end
end
