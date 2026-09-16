require_relative "account_data"

# Existing adapters and callers retain the same contract classes and exceptions.
Provider::BankData = Provider::AccountData
