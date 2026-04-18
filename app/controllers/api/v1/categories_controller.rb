# frozen_string_literal: true

class Api::V1::CategoriesController < Api::V1::BaseController
  include Pagy::Backend

  before_action -> { authorize_scope!(:read) }, only: %i[index show]
  before_action -> { authorize_scope!(:read_write) }, only: %i[create update destroy]
  before_action :set_category, only: %i[show update destroy]

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
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "CategoriesController#show error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    @category = family.categories.new(category_params)

    # Auto-assign color if not provided
    @category.color ||= Category::COLORS.sample

    # Auto-assign icon if not provided
    @category.lucide_icon ||= Category.suggested_icon(@category.name)

    # Validate parent belongs to same family
    if @category.parent_id.present?
      unless family.categories.exists?(id: @category.parent_id)
        render json: {
          error: "validation_failed",
          message: "Parent category not found in this family",
          errors: [ "Parent category not found in this family" ]
        }, status: :unprocessable_entity
        return
      end
    end

    if @category.save
      @category = family.categories.includes(:parent, :subcategories).find(@category.id)
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: @category.errors.full_messages.join(", "),
        errors: @category.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "CategoriesController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  def update
    # Validate parent belongs to same family if parent_id is being changed
    if params[:category]&.key?(:parent_id) && params[:category][:parent_id].present?
      family = current_resource_owner.family
      unless family.categories.exists?(id: params[:category][:parent_id])
        render json: {
          error: "validation_failed",
          message: "Parent category not found in this family",
          errors: [ "Parent category not found in this family" ]
        }, status: :unprocessable_entity
        return
      end
    end

    if @category.update(category_params)
      @category = current_resource_owner.family.categories.includes(:parent, :subcategories).find(@category.id)
      render :show
    else
      render json: {
        error: "validation_failed",
        message: @category.errors.full_messages.join(", "),
        errors: @category.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "CategoriesController#update error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  def destroy
    @category.destroy!
    head :no_content
  rescue => e
    Rails.logger.error "CategoriesController#destroy error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
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

    def category_params
      params.require(:category).permit(:name, :color, :lucide_icon, :parent_id)
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
