# frozen_string_literal: true

class Api::V1::ValuationsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update ]
  before_action :set_valuation, only: [ :show, :update ]
  before_action :ensure_write_permission, only: [ :update ]
  # The typed readers raise a 422 that the actions' catch-all rescues would
  # turn into a 500, so they run here.
  before_action :set_search, only: :index
  before_action :set_upsert, only: :create

  def index
    @per_page = safe_per_page_param

    @pagy, @entries = pagy(
      @search.valuations_scope.includes(:account, :entryable).reverse_chronological,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue => e
    Rails.logger.error "ValuationsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "ValuationsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    unless valuation_account_id.present?
      render json: {
        error: "validation_failed",
        message: "Account ID is required",
        errors: [ "Account ID is required" ]
      }, status: :unprocessable_entity
      return
    end

    unless valuation_params[:amount].present?
      render json: {
        error: "validation_failed",
        message: "Amount is required",
        errors: [ "Amount is required" ]
      }, status: :unprocessable_entity
      return
    end

    unless valuation_params[:date].present?
      render json: {
        error: "validation_failed",
        message: "Date is required",
        errors: [ "Date is required" ]
      }, status: :unprocessable_entity
      return
    end

    account = current_resource_owner.family.accounts.writable_by(current_resource_owner).find(valuation_account_id)
    existing_write = false

    create_success = false
    error_payload = nil

    ActiveRecord::Base.transaction do
      account.lock! if @upsert
      existing_write = account.entries.valuations.exists?(date: valuation_params[:date]) if @upsert

      # upsert=true only affects response status; reconciliation owns write behavior.
      result = account.create_reconciliation(
        balance: valuation_params[:amount],
        date: valuation_params[:date]
      )

      unless result.success?
        error_payload = {
          error: "validation_failed",
          message: "Valuation could not be created",
          errors: [ result.error_message ]
        }
        raise ActiveRecord::Rollback
      end

      @entry = account.entries.valuations.find_by!(date: valuation_params[:date])
      @valuation = @entry.entryable

      if valuation_params.key?(:notes)
        unless @entry.update(notes: valuation_params[:notes])
          error_payload = {
            error: "validation_failed",
            message: "Valuation could not be created",
            errors: @entry.errors.full_messages
          }
          raise ActiveRecord::Rollback
        end
      end

      create_success = true
    end

    unless create_success
      render json: error_payload, status: :unprocessable_entity
      return
    end

    render :show, status: @upsert && existing_write ? :ok : :created

  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Account or valuation entry not found"
    }, status: :not_found
  rescue => e
    Rails.logger.error "ValuationsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def update
    if valuation_params[:date].present? || valuation_params[:amount].present?
      unless valuation_params[:date].present? && valuation_params[:amount].present?
        render json: {
          error: "validation_failed",
          message: "Both amount and date are required when updating reconciliation",
          errors: [ "Amount and date must both be provided" ]
        }, status: :unprocessable_entity
        return
      end

      update_success = false
      error_payload = nil
      updated_entry = nil

      ActiveRecord::Base.transaction do
        result = @entry.account.update_reconciliation(
          @entry,
          balance: valuation_params[:amount],
          date: valuation_params[:date]
        )

        unless result.success?
          error_payload = {
            error: "validation_failed",
            message: "Valuation could not be updated",
            errors: [ result.error_message ]
          }
          raise ActiveRecord::Rollback
        end

        updated_entry = @entry.account.entries.valuations.find_by!(date: valuation_params[:date])

        if valuation_params.key?(:notes)
          unless updated_entry.update(notes: valuation_params[:notes])
            error_payload = {
              error: "validation_failed",
              message: "Valuation could not be updated",
              errors: updated_entry.errors.full_messages
            }
            raise ActiveRecord::Rollback
          end
        end

        update_success = true
      end

      unless update_success
        render json: error_payload, status: :unprocessable_entity
        return
      end

      @entry = updated_entry
      @valuation = @entry.entryable
      render :show
    else
      if valuation_params.key?(:notes)
        unless @entry.update(notes: valuation_params[:notes])
          render json: {
            error: "validation_failed",
            message: "Valuation could not be updated",
            errors: @entry.errors.full_messages
          }, status: :unprocessable_entity
          return
        end
      end
      @entry.reload
      @valuation = @entry.entryable
      render :show
    end

  rescue => e
    Rails.logger.error "ValuationsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    # Valuation entries on accounts the caller can at least read.
    def accessible_valuation_entries
      family = current_resource_owner.family
      family.entries.where(
        entryable_type: "Valuation",
        account_id: family.accounts.accessible_by(current_resource_owner).select(:id)
      )
    end

    def set_valuation
      # Load through accessible accounts only: a valuation on an account the
      # caller cannot see is a 404. Write access is checked next
      # (ensure_write_permission).
      @entry = accessible_valuation_entries.find(params[:id])
      @valuation = @entry.entryable
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Valuation not found"
      }, status: :not_found
    end

    # A valuation the caller can see but not change is a 403, not a 404.
    def ensure_write_permission
      require_api_account_permission!(@entry.account, resource: "valuation")
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_search
      @search = Valuation::Search.new(accessible_valuation_entries, filters: {
        account_id: uuid_filter_param(:account_id),
        start_date: date_filter_param(:start_date),
        end_date: date_filter_param(:end_date)
      })
    end

    def valuation_account_id
      params.dig(:valuation, :account_id)
    end

    def valuation_params
      params.require(:valuation).permit(:amount, :date, :notes)
    end

    # The top-level flag wins over valuation[upsert].
    def set_upsert
      @upsert = boolean_filter_param(:upsert)
      @upsert = boolean_filter_param(:upsert, within: :valuation) if @upsert.nil?
    end
end
