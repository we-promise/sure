require_relative "../account_data/account_data_generator"

# Application credentials do not make bank connections global: each connection
# still belongs to a family and can also hold connection tokens (e.g. Plaid).
class Provider::GlobalGenerator < Provider::AccountDataGenerator
  class_option :credential_scope, type: :string, default: "application",
    enum: %w[connection application], desc: "Scope of the declared configuration fields"
end
