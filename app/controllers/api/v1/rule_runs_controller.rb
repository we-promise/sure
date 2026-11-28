# frozen_string_literal: true

class Api::V1::RuleRunsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_rule_run, only: :show
  before_action :set_search, only: :index

  def index
    @per_page = safe_per_page_param
    @pagy, @rule_runs = pagy(
      @search.rule_runs_scope.recent,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_rule_run
      raise ActiveRecord::RecordNotFound, "Rule run not found" unless valid_uuid?(params[:id])

      @rule_run = rule_runs_scope.find(params[:id])
    end

    def set_search
      @search = RuleRun::Search.new(
        rule_runs_scope,
        filters: {
          rule_id: uuid_filter_param(:rule_id),
          status: enum_filter_param(:status, RuleRun::STATUSES),
          execution_type: enum_filter_param(:execution_type, RuleRun::EXECUTION_TYPES),
          start_executed_at: time_filter_param(:start_executed_at),
          end_executed_at: time_filter_param(:end_executed_at)
        }
      )
    end

    def rule_runs_scope
      RuleRun
        .joins(:rule)
        .where(rules: { family_id: current_resource_owner.family.id })
        .includes(:rule)
    end
end
