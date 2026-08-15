class Provider::YaxiAdapter < Provider::Base
  include Provider::Configurable
  include Provider::InstitutionMetadata

  Provider::Factory.register("YaxiAccount", self)

  configure do
    description <<~MARKDOWN
      Connect European bank accounts through [YAXI](https://hub.yaxi.tech). Sure signs short-lived service tickets and verifies every result. Online-banking credentials stay encrypted in this browser and are never sent to Sure.
    MARKDOWN

    field :key_id,
          label: "API key ID",
          required: true,
          env_key: "YAXI_KEY_ID",
          description: "The ID of the YAXI API key (starts with api-key-)"

    field :secret,
          label: "API secret",
          required: true,
          secret: true,
          env_key: "YAXI_SECRET",
          description: "The Base64 secret shown once when the API key is created"

    field :environment,
          label: "Environment",
          env_key: "YAXI_ENVIRONMENT",
          default: "production",
          description: "production or integration"
  end

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.connection_configs(family:)
    return [] unless configured?

    [ {
      key: "yaxi",
      name: "YAXI",
      description: "Connect a European bank without sharing credentials with Sure",
      can_connect: true,
      new_account_path: ->(_accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_yaxi_item_path(return_to: return_to)
      },
      existing_account_path: nil
    } ]
  end

  def self.build_provider
    return nil unless configured?

    Provider::Yaxi.new(
      key_id: config_value(:key_id),
      secret: config_value(:secret),
      environment: config_value(:environment)
    )
  end

  def provider_name
    "yaxi"
  end

  def institution_name
    provider_account.yaxi_item.institution_name
  end

  def institution_url
    "https://yaxi.tech"
  end
end
