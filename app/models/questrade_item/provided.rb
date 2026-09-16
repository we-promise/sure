# frozen_string_literal: true

module QuestradeItem::Provided
  extend ActiveSupport::Concern

  def questrade_provider
    return nil unless credentials_configured?

    QuestradeItem::CredentialSession::Client.new(self)
  end
end
