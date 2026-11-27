# Each Ai::GenerationJob claims its step of the run as it applies its batch, so a replayed job, or a
# second copy of one, can't report the same batch to a RuleRun twice (#5077). next_job holds the
# arguments the last committed step queues next, for a replay of a job that ended before queuing it.
class AddStepToAiGenerationRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_generation_runs, :step, :integer, null: false, default: 0
    add_column :ai_generation_runs, :next_job, :jsonb
  end
end
