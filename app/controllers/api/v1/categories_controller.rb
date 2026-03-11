# frozen_string_literal: true

class Api::V1::CategoriesController < Api::V1::BaseController
  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update ]
  before_action :set_category, only: [ :show, :update ]

  def index
    family = current_resource_owner.family
    categories_query = family.categories.includes(:parent, :subcategories).alphabetically

    @categories = apply_filters(categories_query)

    render :index
  rescue => e
    Rails.logger.error "CategoriesController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "CategoriesController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    if category_params[:parent_id].present?
      parent = family.categories.find_by(id: category_params[:parent_id])

      unless parent
        render json: {
          error: "validation_failed",
          message: "Parent category not found"
        }, status: :unprocessable_entity
        return
      end

      if parent.subcategory?
        render json: {
          error: "validation_failed",
          message: "Parent must be a root category"
        }, status: :unprocessable_entity
        return
      end
    end

    attrs = {
      name: category_params[:name],
      classification: category_params[:classification]
    }
    attrs[:color]       = category_params[:color] if category_params[:color].present?
    attrs[:lucide_icon] = category_params[:icon]  if category_params[:icon].present?
    attrs[:parent_id]   = category_params[:parent_id] if category_params[:parent_id].present?

    @category = family.categories.new(attrs)

    if @category.save
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Category could not be created",
        errors: @category.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue => e
    Rails.logger.error "CategoriesController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def update
    if params[:category]&.key?(:parent_id) && category_params[:parent_id].present?
      family = current_resource_owner.family
      parent = family.categories.find_by(id: category_params[:parent_id])

      unless parent
        render json: {
          error: "validation_failed",
          message: "Parent category not found"
        }, status: :unprocessable_entity
        return
      end

      if parent.subcategory?
        render json: {
          error: "validation_failed",
          message: "Parent must be a root category"
        }, status: :unprocessable_entity
        return
      end
    end

    attrs = {}
    attrs[:name]           = category_params[:name]           if params[:category]&.key?(:name)
    attrs[:classification] = category_params[:classification] if params[:category]&.key?(:classification)
    attrs[:color]          = category_params[:color]          if params[:category]&.key?(:color)
    attrs[:lucide_icon]    = category_params[:icon]           if params[:category]&.key?(:icon)
    attrs[:parent_id]      = category_params[:parent_id]      if params[:category]&.key?(:parent_id)

    if @category.update(attrs)
      render :show
    else
      render json: {
        error: "validation_failed",
        message: "Category could not be updated",
        errors: @category.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue => e
    Rails.logger.error "CategoriesController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
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
      authorize_scope!(:write)
    end

    def category_params
      params.require(:category).permit(:name, :classification, :color, :icon, :parent_id)
    end

    def apply_filters(query)
      if params[:classification].present?
        query = query.where(classification: params[:classification])
      end

      if params[:roots_only].present? && ActiveModel::Type::Boolean.new.cast(params[:roots_only])
        query = query.roots
      end

      if params[:parent_id].present?
        query = query.where(parent_id: params[:parent_id])
      end

      query
    end
end
