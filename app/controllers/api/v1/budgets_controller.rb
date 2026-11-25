# frozen_string_literal: true

class Api::V1::BudgetsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_search, only: :index
  before_action :set_budget, only: :show

  def index
    @per_page = safe_per_page_param

    @pagy, @budgets = pagy(
      @search.budgets_scope.order(start_date: :desc),
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_search
      @search = Budget::Search.new(
        budgets_scope,
        filters: { start_date: date_filter_param(:start_date), end_date: date_filter_param(:end_date) }
      )
    end

    def set_budget
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @budget = budgets_scope.find(params[:id])
    end

    # This API is read-only, so read-write and read-only shares count alike.
    def budgets_scope
      current_resource_owner.family.budgets
        .where(user_id: Budget.visible_owner_ids(current_resource_owner))
        .includes(:user, budget_categories: :category)
    end
end
