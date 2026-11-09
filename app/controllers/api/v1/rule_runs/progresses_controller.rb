# frozen_string_literal: true

# How far a rule run has got: its AI transactions count down as each batch is applied, so a
# client can poll this until `finished`.
class Api::V1::RuleRuns::ProgressesController < Api::V1::BaseController
  before_action -> { authorize_scope!(:read) }

  def show
    raise ActiveRecord::RecordNotFound, "Rule run not found" unless valid_uuid?(params[:rule_run_id])

    @rule_run = RuleRun.for_family(current_resource_owner.family).find(params[:rule_run_id])
  end
end
