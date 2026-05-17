class SyncAllProvidersJob < ApplicationJob
  queue_as :high_priority
  sidekiq_options lock: :until_executed, lock_args: ->(args) { [ args.first ] }, on_conflict: :log

  def perform(family_id)
    family = Family.find_by(id: family_id)
    family&.sync_later
  end
end
