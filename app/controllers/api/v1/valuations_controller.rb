# frozen_string_literal: true

class Api::V1::ValuationsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: [ :show ]
  before_action :ensure_write_scope, only: [ :create, :update ]
  before_action :set_entry, only: [ :show, :update ]

  def show
    render :show
  rescue => e
    Rails.logger.error "ValuationsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def create
    account = current_resource_owner.family.accounts.find(valuation_account_id)

    result = account.create_reconciliation(
      balance: valuation_params[:amount],
      date: valuation_params[:date]
    )

    if result.success?
      @entry = account.entries.valuations.find_by(date: valuation_params[:date])
      @valuation = @entry.entryable

      if valuation_params[:notes].present?
        @entry.update!(notes: valuation_params[:notes])
      end

      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Valuation could not be created",
        errors: [ result.error_message ]
      }, status: :unprocessable_entity
    end

  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Account not found"
    }, status: :not_found
  rescue => e
    Rails.logger.error "ValuationsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def update
    if valuation_params[:notes].present?
      @entry.update!(notes: valuation_params[:notes])
    end

    if valuation_params[:date].present? && valuation_params[:amount].present?
      result = @entry.account.update_reconciliation(
        @entry,
        balance: valuation_params[:amount],
        date: valuation_params[:date]
      )

      if result.success?
        @entry.reload
        @valuation = @entry.entryable
        render :show
      else
        render json: {
          error: "validation_failed",
          message: "Valuation could not be updated",
          errors: [ result.error_message ]
        }, status: :unprocessable_entity
      end
    else
      @entry.reload
      @valuation = @entry.entryable
      render :show
    end

  rescue => e
    Rails.logger.error "ValuationsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  private

    def set_entry
      @entry = current_resource_owner.family.entries.find(params[:id])
      @valuation = @entry.entryable
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Valuation not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def valuation_account_id
      params.dig(:valuation, :account_id)
    end

    def valuation_params
      params.require(:valuation).permit(:amount, :date, :notes)
    end
end
