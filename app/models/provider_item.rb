# frozen_string_literal: true

# Base class for an account provider's connection: one family's authorised link
# to that provider. Abstract, so each provider keeps its own `<key>_items` table
# and Syncable/AccountProvider rows keep recording the provider's own class name.
#
# Its adapter's `declares_connection` names the provider key and the accounts
# association; a subclass must define `import_latest_<key>_data(sync_start_date:)`.
class ProviderItem < ApplicationRecord
  self.abstract_class = true

  include Syncable, Unlinking

  def self.connection_declaration
    Provider::Factory.connection_declarations.find { |declaration| declaration[:type] == name } ||
      raise(NotImplementedError, "#{name} has no declares_connection on its adapter")
  end

  def self.provider_key
    connection_declaration[:key]
  end

  def provider_key
    self.class.provider_key
  end

  def provider_accounts
    public_send(self.class.connection_declaration[:accounts])
  end
end
