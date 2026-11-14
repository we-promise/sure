# frozen_string_literal: true

# Base class for an account provider's connection: one family's authorised link
# to that provider. Abstract, so each provider keeps its own `<key>_items` table
# and Syncable/AccountProvider rows keep recording the provider's own class name.
#
# A subclass must define `has_many :<key>_accounts` and
# `import_latest_<key>_data(sync_start_date:)`.
class ProviderItem < ApplicationRecord
  self.abstract_class = true

  include Syncable, Unlinking

  def self.provider_key
    model_name.singular.delete_suffix("_item")
  end

  def provider_key
    self.class.provider_key
  end

  def provider_accounts
    public_send(:"#{provider_key}_accounts")
  end
end
