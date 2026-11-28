# frozen_string_literal: true

class Api::V1::RulesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_rule, only: :show
  before_action :set_search, only: :index

  def index
    @per_page = safe_per_page_param
    @pagy, @rules = pagy(
      @search.rules_scope.order(:created_at, :id),
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_rule
      @rule = rules_scope.find(params[:id])
    end

    def set_search
      @search = Rule::Search.new(
        rules_scope,
        filters: {
          resource_type: enum_filter_param(:resource_type, Rule::SUPPORTED_RESOURCE_TYPES),
          active: boolean_filter_param(:active)
        }
      )
    end

    def rules_scope
      current_resource_owner.family.rules.includes(:actions, conditions: :sub_conditions)
    end
end
