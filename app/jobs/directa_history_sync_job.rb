# frozen_string_literal: true

class DirectaHistorySyncJob < ApplicationJob
  queue_as :scheduled

  sidekiq_options lock: :until_executed,
                  lock_args: ->(args) { [ args.first ] },
                  on_conflict: :log

  def perform(directa_item)
    item = directa_item.is_a?(DirectaItem) ? directa_item : DirectaItem.find_by(id: directa_item)
    return unless item

    DirectaItem::HistorySyncer.new(item).perform
  end
end
