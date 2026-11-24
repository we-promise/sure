# The ids one Ai::GenerationJob chain works through, frozen when the run is queued, one row per
# item in the order they were given. Each job carries the run's id, a cursor into it and the few
# ids its last batch left unanswered, and reads only one window from here (Window), so a job
# touches about one batch's worth of rows however long the run is (#5077). `step` is the next job
# step to commit (Ai::GenerationJob). The run is deleted in the transaction where the requester
# hears the end; DataCleanerJob sweeps any a dead job left behind.
class Ai::GenerationRun < ApplicationRecord
  self.table_name = "ai_generation_runs"

  INSERT_SLICE = 5_000
  IDLE_BEFORE_DELIVERY = 1.hour
  MAX_DELIVERIES = 3

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

  # The outbox (docs/proposals/v0.8/ai-generation-outbox.md). Starts a run of `ids` with its first
  # job saved in next_job, and queues that job once the run commits, together with any transaction
  # around this one, such as the rule run's count (Rule::ActionExecutor.queue_ai_jobs_after). A
  # queue that refuses the job, or raises, leaves it in next_job, and Ai::GenerationDeliveryJob
  # queues it again. Returns true; raises only when the run can't be saved.
  def self.enqueue(feature, family:, ids:, **args)
    transaction do
      run = start!(family:, feature:, ids:)
      run.update_columns(next_job: { args: { run_id: run.id, cursor: 0, pending: [], step: 0, family_id: family.id, **args }.compact,
                                     applied: 0, answered_before: false })
      ActiveRecord.after_all_transactions_commit { run.deliver }
    end
    true
  end

  # Runs with a step saved that no job has touched for IDLE_BEFORE_DELIVERY: the step's job was
  # refused or lost by the queue, or died before it committed. Compared on the database's clock.
  scope :undelivered, -> { where.not(next_job: nil).where("ai_generation_runs.updated_at < now() - make_interval(secs => ?)", IDLE_BEFORE_DELIVERY.to_i) }

  # Runs no job has touched in a week: a run still making progress is kept however long it takes.
  def self.sweep(idle_for: 7.days) = where(updated_at: ...idle_for.ago).delete_all

  # Queues the step saved in next_job. Returns whether it was queued.
  def deliver
    job = next_job.deep_symbolize_keys
    Ai::GenerationJob.enqueue_step(feature.to_sym, job[:args], job[:applied], job[:answered_before])
  end

  # For Ai::GenerationDeliveryJob: queues an undelivered run's step again, or after MAX_DELIVERIES
  # of that step gives the run up, so its requester hears that the job couldn't be run.
  def redeliver
    if claim_delivery
      DebugLogEntry.capture(category: "ai", level: "warn", message: "AI job delivered again: no job ran its step for an hour",
                            source: self.class.name, family_id:, metadata: delivery_metadata)
      reload.deliver
    elsif self.class.undelivered.exists?(id:)
      DebugLogEntry.capture(category: "ai", level: "error", message: "AI run given up: its job couldn't be run after #{MAX_DELIVERIES} deliveries",
                            source: self.class.name, family_id:, metadata: delivery_metadata)
      job = next_job.deep_symbolize_keys
      Ai::GenerationJob.new(feature.to_sym, job[:args], job[:applied], job[:answered_before])
                       .give_up(Ai::GenerationJob::Undelivered.new("the AI job couldn't be run after #{MAX_DELIVERIES} deliveries"))
    end
  end

  # [position, item_id] pairs from `position` on, in order.
  def ids_from(position, limit) = items.where(position: position..).order(:position).limit(limit).pluck(:position, :item_id)

  def window(cursor:, pending:, size:) = Window.new(self, cursor:, pending:, size:)

  private
    # Counts one more delivery of the saved step, in the statement that checks the run is still
    # undelivered and under the cap, so two delivery jobs at once can't both pass it. Touches the
    # run, which the next check goes by.
    def claim_delivery
      deliveries = "COALESCE((next_job->>'deliveries')::int, 0)"
      self.class.undelivered.where(id:).where("#{deliveries} < ?", MAX_DELIVERIES)
          .update_all("next_job = jsonb_set(next_job, '{deliveries}', to_jsonb(#{deliveries} + 1)), updated_at = now()")
          .positive?
    end

    def delivery_metadata
      { run_id: id, feature:, step:, deliveries: next_job&.dig("deliveries").to_i, idle_since: updated_at }
    end
end
