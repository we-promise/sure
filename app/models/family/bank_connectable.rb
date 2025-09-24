module Family::BankConnectable
  extend ActiveSupport::Concern

  included do
    has_many :bank_connections, dependent: :destroy
  end

  def create_bank_connection!(provider:, credentials:, item_name: nil)
    meta = Provider::Banks::Registry.find(provider)
    raise ArgumentError, "Unknown bank provider: #{provider}" unless meta

    instance = Provider::Banks::Registry.get_instance(provider, credentials)

    # Validate credentials by attempting a call
    instance.verify_credentials!

    connection = bank_connections.create!(
      name: item_name || meta.display_name,
      provider: provider,
      credentials: credentials.to_json
    )

    connection.sync_later
    connection
  end
end
