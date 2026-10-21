# frozen_string_literal: true

module FioItem::Provided
  extend ActiveSupport::Concern

  def fio_provider
    return nil unless credentials_configured?

    Provider::Fio.new(token)
  end

  def syncer
    FioItem::Syncer.new(self)
  end
end
