# frozen_string_literal: true

# Base class for an account as an account provider reports it. Abstract, so each
# provider keeps its own `<key>_accounts` table and links keep the provider's own
# class name as their `provider_type`.
class ProviderAccount < ApplicationRecord
  self.abstract_class = true

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  def current_account
    account
  end
end
