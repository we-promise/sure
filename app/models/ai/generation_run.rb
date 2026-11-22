# The ids one Ai::GenerationJob chain works through, frozen when the run is queued, one row per
# item in the order they were given. Each job carries the run's id, a cursor into it and the few
# ids its last batch left unanswered, and reads only one window from here (Window), so a job
# touches about one batch's worth of rows however long the run is (#5077). `step` is the next job
# step to commit (Ai::GenerationJob). The run is deleted in the transaction where the requester
# hears the end; DataCleanerJob sweeps any a dead job left behind.
class Ai::GenerationRun < ApplicationRecord
  self.table_name = "ai_generation_runs"

  INSERT_SLICE = 5_000

  belongs_to :family
  # The database deletes a run's items with it.
  has_many :items, class_name: "Ai::GenerationRun::Item", foreign_key: :run_id, inverse_of: false

  def self.start!(family:, feature:, ids:)
    transaction do
      run = create!(family:, feature: feature.to_s, item_count: ids.size)
      ids.each_slice(INSERT_SLICE).with_index do |slice, n|
        Item.insert_all(slice.each_with_index.map { |id, i| { run_id: run.id, position: n * INSERT_SLICE + i, item_id: id } })
      end
      run
    end
  end

  # Starts a run of `ids` and queues its first job. Returns what perform_later returns; a run
  # whose job couldn't be queued is deleted, whether the enqueue returned false or raised.
  def self.enqueue(feature, family:, ids:, **args)
    run = start!(family:, feature:, ids:)
    queued = false
    queued = Ai::GenerationJob.perform_later(feature, { run_id: run.id, cursor: 0, pending: [], step: 0, family_id: family.id, **args }.compact)
  ensure
    run&.destroy unless queued
  end

  # Runs no job has touched in a week: a run still making progress is kept however long it takes.
  def self.sweep(idle_for: 7.days) = where(updated_at: ...idle_for.ago).delete_all

  # [position, item_id] pairs from `position` on, in order.
  def ids_from(position, limit) = items.where(position: position..).order(:position).limit(limit).pluck(:position, :item_id)

  def window(cursor:, pending:, size:) = Window.new(self, cursor:, pending:, size:)
end
