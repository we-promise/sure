# frozen_string_literal: true

class Api::V1::RuleRunsController < Api::V1::BaseController
  include Pagy::Backend

  STATUSES = %w[pending success failed].freeze
  EXECUTION_TYPES = %w[manual scheduled].freeze
  InvalidFilterError = Class.new(StandardError)

  before_action :ensure_read_scope
  before_action :set_rule_run, only: :show

  def index
    rule_runs_query = apply_filters(rule_runs_scope).recent
    @per_page = safe_per_page_param

    @pagy, @rule_runs = pagy(
      rule_runs_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  private

    def set_rule_run
      raise ActiveRecord::RecordNotFound, "Rule run not found" unless valid_uuid?(params[:id])

      @rule_run = rule_runs_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def rule_runs_scope
      RuleRun
        .joins(:rule)
        .where(rules: { family_id: Current.family.id })
        .includes(:rule)
    end

    def apply_filters(query)
      if params[:rule_id].present?
        raise InvalidFilterError, "rule_id must be a valid UUID" unless valid_uuid?(params[:rule_id])

        query = query.where(rule_id: params[:rule_id])
      end

      if params[:status].present?
        raise InvalidFilterError, "status must be one of: #{STATUSES.join(', ')}" unless STATUSES.include?(params[:status])

        query = query.where(status: params[:status])
      end

      if params[:execution_type].present?
        unless EXECUTION_TYPES.include?(params[:execution_type])
          raise InvalidFilterError, "execution_type must be one of: #{EXECUTION_TYPES.join(', ')}"
        end

        query = query.where(execution_type: params[:execution_type])
      end

      query = query.where("rule_runs.executed_at >= ?", parse_time_param(:start_executed_at)) if params[:start_executed_at].present?
      query = query.where("rule_runs.executed_at <= ?", parse_time_param(:end_executed_at)) if params[:end_executed_at].present?
      query
    end

    def parse_time_param(key)
      Time.iso8601(params[key].to_s)
    rescue ArgumentError
      raise InvalidFilterError, "#{key} must be an ISO 8601 timestamp"
    end
end
