# frozen_string_literal: true

class Api::V1::RulesController < Api::V1::BaseController
  include Pagy::Backend

  BOOLEAN_FILTERS = {
    "true" => true,
    "1" => true,
    "false" => false,
    "0" => false
  }.freeze
  RESOURCE_TYPES = %w[transaction].freeze

  before_action :ensure_read_scope
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_rule, only: [ :show, :update, :destroy ]

  def index
    return render_invalid_resource_type_filter if invalid_resource_type_filter?

    @per_page = safe_per_page_param
    rules_query = current_resource_owner.family.rules
      .includes(:actions, conditions: :sub_conditions)
      .order(:created_at, :id)

    rules_query = rules_query.where(resource_type: params[:resource_type]) if params[:resource_type].present?
    if params[:active].present?
      active = parse_boolean_filter(params[:active])
      return if performed?

      rules_query = rules_query.where(active: active)
    end

    @pagy, @rules = pagy(
      rules_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  def create
    @rule = current_resource_owner.family.rules.build(rule_params)

    if @rule.save
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Rule could not be created",
        errors: @rule.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "RulesController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  def update
    if @rule.update(rule_params)
      render :show
    else
      render json: {
        error: "validation_failed",
        message: "Rule could not be updated",
        errors: @rule.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "RulesController#update error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  def destroy
    @rule.destroy!
    render json: { message: "Rule deleted successfully" }, status: :ok
  rescue => e
    Rails.logger.error "RulesController#destroy error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  private

    def set_rule
      @rule = current_resource_owner.family.rules
        .includes(:actions, conditions: :sub_conditions)
        .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "record_not_found", message: "Rule not found" }, status: :not_found
    end

    def rule_params
      params.require(:rule).permit(
        :name, :resource_type, :active, :effective_date,
        conditions_attributes: [
          :id, :condition_type, :operator, :value, :_destroy,
          sub_conditions_attributes: [ :id, :condition_type, :operator, :value, :_destroy ]
        ],
        actions_attributes: [ :id, :action_type, :value, :_destroy ]
      )
    end

    def parse_boolean_filter(value)
      normalized = value.to_s.downcase
      return BOOLEAN_FILTERS[normalized] if BOOLEAN_FILTERS.key?(normalized)

      render_validation_error("active must be one of: true, false, 1, 0")
      nil
    end

    def invalid_resource_type_filter?
      params[:resource_type].present? && !params[:resource_type].in?(RESOURCE_TYPES)
    end

    def render_invalid_resource_type_filter
      render_validation_error("resource_type must be one of: #{RESOURCE_TYPES.join(", ")}")
    end
end
