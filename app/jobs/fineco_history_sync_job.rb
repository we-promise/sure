# frozen_string_literal: true

class FinecoHistorySyncJob < ApplicationJob
  queue_as :scheduled

  sidekiq_options lock: :until_executed,
                  lock_args: ->(args) { [ args.first ] },
                  on_conflict: :log

  def perform(fineco_item)
    item = fineco_item.is_a?(FinecoItem) ? fineco_item : FinecoItem.find_by(id: fineco_item)
    return unless item

    FinecoItem::HistorySyncer.new(item).perform
  end
end
