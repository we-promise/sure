# frozen_string_literal: true

class Api::V1::BudgetsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_budget, only: :show

  def index
    budgets_query = apply_filters(budgets_scope).order(start_date: :desc)
    @per_page = safe_per_page_param

    @pagy, @budgets = pagy(
      budgets_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_budget
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @budget = budgets_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def apply_filters(query)
      query = query.where("budgets.start_date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("budgets.end_date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query
    end

    def budgets_scope
      current_resource_owner.family.budgets.includes(budget_categories: :category)
    end
end
