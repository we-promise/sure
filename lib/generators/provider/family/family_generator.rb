require_relative "../account_data/account_data_generator"

# Compatibility entry point. Family credentials belong to a connection, not a
# provider-specific table. Both entry points generate the same integration package.
class Provider::FamilyGenerator < Provider::AccountDataGenerator
  class_option :credential_scope, type: :string, default: "connection",
    enum: %w[connection application], desc: "Scope of the declared configuration fields"
end
