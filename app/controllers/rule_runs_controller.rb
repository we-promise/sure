class RuleRunsController < ApplicationController
  before_action :set_rule_run

  def download_metadata
    filename = "rule_run_#{@rule_run.id}_metadata.json"
    metadata = @rule_run.run_metadata || {}

    send_data(
      JSON.pretty_generate(metadata),
      filename: filename,
      type: "application/json",
      disposition: "attachment"
    )
  end

  private

    def set_rule_run
      @rule_run = RuleRun.joins(:rule)
                         .where(rules: { family_id: Current.family.id })
                         .find(params[:id])
    end
end
