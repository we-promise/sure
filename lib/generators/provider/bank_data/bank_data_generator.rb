require_relative "../account_data/account_data_generator"

# Compatibility command; all integrations now use the account-data namespace.
class Provider::BankDataGenerator < Provider::AccountDataGenerator
end
