class Provider::YaxiAdapter < Provider::Base
  include Provider::Configurable
  include Provider::InstitutionMetadata

  Provider::Factory.register("YaxiAccount", self)

  configure do
    description -> { I18n.t("yaxi_items.provider_config.description") }

    field :key_id,
          label: -> { I18n.t("yaxi_items.provider_config.key_id.label") },
          required: true,
          env_key: "YAXI_KEY_ID",
          description: -> { I18n.t("yaxi_items.provider_config.key_id.description") }

    field :secret,
          label: -> { I18n.t("yaxi_items.provider_config.secret.label") },
          required: true,
          secret: true,
          env_key: "YAXI_SECRET",
          description: -> { I18n.t("yaxi_items.provider_config.secret.description") }

    field :environment,
          label: -> { I18n.t("yaxi_items.provider_config.environment.label") },
          env_key: "YAXI_ENVIRONMENT",
          default: "production",
          description: -> { I18n.t("yaxi_items.provider_config.environment.description") }
  end

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.connection_configs(family:)
    return [] unless configured?

    [ {
      key: "yaxi",
      name: I18n.t("yaxi_items.provider_config.name"),
      description: I18n.t("yaxi_items.provider_config.connection_description"),
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
