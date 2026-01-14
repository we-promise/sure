# frozen_string_literal: true

class Api::V1::MerchantsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_merchant, only: [ :show, :update, :destroy ]

  def index
    family = current_resource_owner.family
    merchants_query = family.merchants.alphabetically

    # Handle pagination with Pagy
    @pagy, @merchants = pagy(
      merchants_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param

    render :index
  rescue => e
    Rails.logger.error "MerchantsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "MerchantsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family
    @merchant = family.merchants.new(merchant_params)

    if @merchant.save
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Merchant could not be created",
        errors: @merchant.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "MerchantsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def update
    if @merchant.update(merchant_params)
      render :show
    else
      render json: {
        error: "validation_failed",
        message: "Merchant could not be updated",
        errors: @merchant.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "MerchantsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def destroy
    @merchant.destroy!

    render json: {
      message: "Merchant deleted successfully"
    }, status: :ok
  rescue => e
    Rails.logger.error "MerchantsController#destroy error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  private

    def set_merchant
      family = current_resource_owner.family
      @merchant = family.merchants.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Merchant not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def merchant_params
      params.require(:merchant).permit(:name, :color)
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
