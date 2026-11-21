class Ai::GenerationRun::Item < ApplicationRecord
  self.table_name = "ai_generation_run_items"
  self.primary_key = [ :run_id, :position ]
end
