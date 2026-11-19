# frozen_string_literal: true

class Provider::RevolutXAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("RevolutXAccount", self)
  declares_connection key: "revolut_x", name: "Revolut X", lists: { accounts_index: nil }

  def self.supported_account_types
    %w[Crypto]
  end

  def provider_name
    "revolut_x"
  end

  def item
    provider_account.revolut_x_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    institution_metadata_value("domain")
  end

  def institution_name
    institution_metadata_value("name")
  end

  def institution_url
    institution_metadata_value("url")
  end

  def institution_color
    institution_metadata_value("color")
  end

  private

    def institution_metadata_value(key)
      metadata = provider_account.institution_metadata || {}
      metadata[key] || item&.public_send("institution_#{key}")
    end
end
