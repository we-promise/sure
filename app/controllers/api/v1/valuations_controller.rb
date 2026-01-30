# frozen_string_literal: true

class Api::V1::ValuationsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: [ :show ]
  before_action :ensure_write_scope, only: [ :create, :update ]
  before_action :set_valuation, only: [ :show, :update ]

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

    account = current_resource_owner.family.accounts.find(valuation_account_id)

    create_success = false
    error_payload = nil

    ActiveRecord::Base.transaction do
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

    render :show, status: :created

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
      message: "Error: #{e.message}"
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
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  private

    def set_valuation
      @entry = current_resource_owner.family
                 .entries
                 .where(entryable_type: "Valuation")
                 .find(params[:id])
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
