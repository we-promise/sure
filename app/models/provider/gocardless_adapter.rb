class Provider::GocardlessAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  Provider::Factory.register("GocardlessAccount", self)

  SUPPORTED_COUNTRIES = {
    "at" => "Austria",
    "be" => "Belgium",
    "bg" => "Bulgaria",
    "cy" => "Cyprus",
    "cz" => "Czech Republic",
    "de" => "Germany",
    "dk" => "Denmark",
    "ee" => "Estonia",
    "es" => "Spain",
    "fi" => "Finland",
    "fr" => "France",
    "gb" => "United Kingdom",
    "gr" => "Greece",
    "hr" => "Croatia",
    "hu" => "Hungary",
    "ie" => "Ireland",
    "is" => "Iceland",
    "it" => "Italy",
    "li" => "Liechtenstein",
    "lt" => "Lithuania",
    "lu" => "Luxembourg",
    "lv" => "Latvia",
    "mt" => "Malta",
    "nl" => "Netherlands",
    "no" => "Norway",
    "pl" => "Poland",
    "pt" => "Portugal",
    "ro" => "Romania",
    "se" => "Sweden",
    "si" => "Slovenia",
    "sk" => "Slovakia"
  }.freeze

  configure do
    description <<~DESC
      Connect your bank accounts using GoCardless open banking.
      Supports 2,500+ banks across 30+ countries including the UK, Germany,
      France, Spain, Netherlands, and more.

      You will need a free GoCardless Bank Account Data account.
      Get your credentials at: https://bankaccountdata.gocardless.com
    DESC

    field :secret_id,
          label:       "Secret ID",
          required:    true,
          secret:      true,
          env_key:     "GOCARDLESS_SECRET_ID",
          description: "Your GoCardless Bank Account Data secret ID"

    field :secret_key,
          label:       "Secret Key",
          required:    true,
          secret:      true,
          env_key:     "GOCARDLESS_SECRET_KEY",
          description: "Your GoCardless Bank Account Data secret key"
  end

  def provider_name
    "gocardless"
  end

  def self.supported_account_types
    %w[Depository CreditCard Investment Loan OtherAsset]
  end
  def self.connection_configs(family:)
    return [] unless family.can_connect_gocardless?

    [
      {
        key: "gocardless",
        name: "GoCardless",
        description: "Connect your UK bank account via GoCardless open banking",
        can_connect: true,
        new_account_path: ->(accountable_type, return_to) {
          Rails.application.routes.url_helpers.new_item_gocardless_items_path(
            accountable_type: accountable_type,
            return_to:        return_to
          )
        },
        existing_account_path: ->(account_id) {
          Rails.application.routes.url_helpers.select_existing_account_gocardless_items_path(
            account_id: account_id
          )
        }
      }
    ]
  end

  def self.build_provider(family: nil)
    secret_id  = config_value(:secret_id)
    secret_key = config_value(:secret_key)
    return nil unless secret_id.present? && secret_key.present?

    Provider::Gocardless.new(secret_id, secret_key)
  end

  def self.sdk
    build_provider
  end

  def institution_domain
    provider_account.institution_metadata&.dig("domain")
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") ||
      provider_account.gocardless_item&.institution_name
  end

  def institution_url
    provider_account.institution_metadata&.dig("url") ||
      provider_account.gocardless_item&.institution_url
  end

  def institution_color
    provider_account.gocardless_item&.institution_color
  end

  def can_delete_holdings?
    false
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_gocardless_item_path(item)
  end

  def item
    provider_account.gocardless_item
  end

end