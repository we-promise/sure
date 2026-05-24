# frozen_string_literal: true

module Api::V1::TransferDecisionFiltering
  extend ActiveSupport::Concern

  InvalidFilterError = Class.new(StandardError)

  private

    def transfer_decision_scope(model_class)
      model_class
        .where(
          inflow_transaction_id: accessible_transaction_ids,
          outflow_transaction_id: accessible_transaction_ids
        )
        .includes(
          inflow_transaction: { entry: :account },
          outflow_transaction: { entry: :account }
        )
    end

    def apply_transfer_decision_filters(query, status_model: nil)
      query = apply_transfer_status_filter(query, status_model) if status_model
      query = apply_transfer_account_filter(query) if params[:account_id].present?
      query = apply_transfer_date_filter(query) if params[:start_date].present? || params[:end_date].present?
      query
    end

    def accessible_transaction_ids
      accessible_transactions.select(:id)
    end

    def accessible_transactions
      Transaction
        .joins(:entry)
        .where(entries: { account_id: accessible_account_ids })
    end

    def accessible_account_ids
      @accessible_account_ids ||= Current.family.accounts.accessible_by(Current.user).select(:id)
    end

    def apply_transfer_status_filter(query, status_model)
      return query unless params[:status].present?

      unless status_model.statuses.key?(params[:status])
        invalid_filter!("status must be one of: #{status_model.statuses.keys.join(", ")}")
      end

      query.where(status: params[:status])
    end

    def apply_transfer_account_filter(query)
      invalid_filter!("account_id must be a valid UUID") unless valid_uuid?(params[:account_id])

      account_transaction_ids = accessible_transaction_ids_for_account(params[:account_id])
      query
        .where(inflow_transaction_id: account_transaction_ids)
        .or(query.where(outflow_transaction_id: account_transaction_ids))
    end

    def apply_transfer_date_filter(query)
      date_transaction_ids = transfer_date_transaction_ids
      query
        .where(inflow_transaction_id: date_transaction_ids)
        .or(query.where(outflow_transaction_id: date_transaction_ids))
    end

    def accessible_transaction_ids_for_account(account_id)
      Transaction
        .joins(:entry)
        .where(entries: { account_id: accessible_account_ids.where(id: account_id) })
        .select(:id)
    end

    def transfer_date_transaction_ids
      query = accessible_transactions
      query = query.where("entries.date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("entries.date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query.select(:id)
    end

    def parse_date_param(key)
      Date.iso8601(params[key].to_s)
    rescue ArgumentError
      invalid_filter!("#{key} must be an ISO 8601 date")
    end

    def invalid_filter!(message)
      raise InvalidFilterError, message
    end
end
