# frozen_string_literal: true

class Api::V1::CategoriesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: :create
  before_action :set_category, only: :show

  def index
    family = current_resource_owner.family
    categories_query = family.categories.includes(:parent, :subcategories).alphabetically

    # Apply filters
    categories_query = apply_filters(categories_query)

    # Handle pagination with Pagy
    @pagy, @categories = pagy(
      categories_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param

    render :index
  rescue => e
    Rails.logger.error "CategoriesController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "CategoriesController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family
    attrs = category_params

    if attrs[:parent_id].present? && !family.categories.exists?(id: attrs[:parent_id])
      return render json: {
        error: "unprocessable_entity",
        message: "Parent must be a category in your family"
      }, status: :unprocessable_entity
    end

    @category = family.categories.new(attrs)
    @category.lucide_icon = Category.suggested_icon(@category.name) if @category.lucide_icon.blank?

    if @category.save
      render :show, status: :created
    else
      render json: {
        error: "unprocessable_entity",
        message: @category.errors.full_messages.join(", ")
      }, status: :unprocessable_entity
    end
  end

  private

    def set_category
      family = current_resource_owner.family
      @category = family.categories.includes(:parent, :subcategories).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Category not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:read_write)
    end

    def category_params
      permitted = params.require(:category).permit(:name, :color, :icon, :parent_id)
      icon = permitted.delete(:icon)
      permitted[:lucide_icon] = icon if icon.present?
      permitted
    end

    def apply_filters(query)
      # Filter for root categories only (no parent)
      if params[:roots_only].present? && ActiveModel::Type::Boolean.new.cast(params[:roots_only])
        query = query.roots
      end

      # Filter by parent_id
      if params[:parent_id].present?
        query = query.where(parent_id: params[:parent_id])
      end

      query
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i

      case per_page
      when 1..100
        per_page
      else
        25
      end
    end
end
