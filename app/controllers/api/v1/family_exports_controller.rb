# frozen_string_literal: true

class Api::V1::FamilyExportsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show, :download ]
  before_action :ensure_write_scope, only: [ :create ]
  before_action :ensure_admin
  before_action :set_family_export, only: [ :show, :download ]

  def index
    family_exports_query = current_resource_owner.family
      .family_exports
      .with_attached_export_file
      .ordered

    @per_page = safe_per_page_param
    @pagy, @family_exports = pagy(
      family_exports_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue StandardError => e
    Rails.logger.error "FamilyExportsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    render :show
  end

  def create
    if unsupported_create_params?
      render json: {
        error: "invalid_params",
        message: "Family export creation does not accept request parameters"
      }, status: :unprocessable_entity
      return
    end

    @family_export = current_resource_owner.family.family_exports.create!
    FamilyDataExportJob.perform_later(@family_export)

    render :show, status: :accepted
  rescue StandardError => e
    Rails.logger.error "FamilyExportsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def download
    unless @family_export.downloadable?
      render json: {
        error: "export_not_ready",
        message: "Export is not ready for download"
      }, status: :conflict
      return
    end

    redirect_to rails_blob_url(@family_export.export_file, disposition: "attachment"), allow_other_host: true
  rescue StandardError => e
    Rails.logger.error "FamilyExportsController#download error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    def set_family_export
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @family_export = current_resource_owner.family.family_exports.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_admin
      return if current_resource_owner.admin?

      render json: {
        error: "forbidden",
        message: "Family exports require a family admin"
      }, status: :forbidden
    end

    def unsupported_create_params?
      params.except(:controller, :action, :format).present?
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
