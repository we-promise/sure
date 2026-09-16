# frozen_string_literal: true

module WiseItem::Provided
  extend ActiveSupport::Concern

  def syncer
    WiseItem::Syncer.new(self)
  end
end
