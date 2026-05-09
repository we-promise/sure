# frozen_string_literal: true

class Api::V1::TransactionsController < Api::V1::BaseController
  include Pagy::Backend

  MAX_BATCH_SIZE = 100

  # Ensure proper scope authorization for read vs write access
  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy, :batch_create, :batch_update ]
  before_action :set_transaction, only: [ :show, :update, :destroy ]

  def index
    family = current_resource_owner.family
    accessible_account_ids = family.accounts
      .accessible_by(current_resource_owner)
      .where.not(status: "pending_deletion")
      .select(:id)
    transactions_query = family.transactions
      .joins(:entry).where(entries: { account_id: accessible_account_ids })

    # Apply filters
    transactions_query = apply_filters(transactions_query)

    # Apply search
    transactions_query = apply_search(transactions_query) if params[:search].present?

    # Include necessary associations for efficient queries
    transactions_query = transactions_query.includes(
      { entry: :account },
      :category, :merchant, :tags,
      transfer_as_outflow: { inflow_transaction: { entry: :account } },
      transfer_as_inflow: { outflow_transaction: { entry: :account } }
    ).reverse_chronological

    # Handle pagination with Pagy
    @pagy, @transactions = pagy(
      transactions_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    # Make per_page available to the template
    @per_page = safe_per_page_param

    # Rails will automatically use app/views/api/v1/transactions/index.json.jbuilder
    render :index

  rescue => e
    Rails.logger.error "TransactionsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    # Rails will automatically use app/views/api/v1/transactions/show.json.jbuilder
    render :show

  rescue => e
    Rails.logger.error "TransactionsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    # Validate account_id is present
    unless account_id_param.present?
      render json: {
        error: "validation_failed",
        message: "Account ID is required",
        errors: [ "Account ID is required" ]
      }, status: :unprocessable_entity
      return
    end

    if idempotency_source_param.present? && idempotency_external_id.blank?
      render json: {
        error: "validation_failed",
        message: "Source requires external_id",
        errors: [ "Source requires external_id" ]
      }, status: :unprocessable_entity
      return
    end

    account = family.accounts.writable_by(current_resource_owner).find(account_id_param)

    if idempotency_key_requested? && (existing_entry = existing_idempotent_entry(account))
      return render_existing_idempotent_entry(existing_entry)
    end

    @entry = account.entries.new(entry_params_for_create)

    if @entry.save
      @entry.sync_account_later
      @entry.lock_saved_attributes!
      @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?

      @transaction = @entry.transaction
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Transaction could not be created",
        errors: @entry.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue ActiveRecord::RecordNotUnique
    if idempotency_key_requested? && account && (existing_entry = existing_idempotent_entry(account))
      render_existing_idempotent_entry(existing_entry)
    else
      raise
    end
  rescue => e
    Rails.logger.error "TransactionsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
end

  def update
    if @entry.split_child?
      render json: { error: "validation_failed", message: "Split child transactions cannot be edited directly. Use the split editor." }, status: :unprocessable_entity
      return
    end

    if @entry.split_parent? && split_financial_fields_changed?
      render json: { error: "validation_failed", message: "Split parent amount, date, and type cannot be changed directly. Use the split editor." }, status: :unprocessable_entity
      return
    end

    Entry.transaction do
      if @entry.update(entry_params_for_update(transaction_params, @entry))
        # Handle tags separately - only when explicitly provided in the request
        # This allows clearing tags with tag_ids: [] while preserving tags when not specified
        if tags_provided?
          @entry.transaction.tag_ids = transaction_params[:tag_ids] || []
          @entry.transaction.save!
          @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?
        end

        @entry.sync_account_later
        @entry.lock_saved_attributes!

        @transaction = @entry.transaction
        render :show
      else
        render json: {
          error: "validation_failed",
          message: "Transaction could not be updated",
          errors: @entry.errors.full_messages
        }, status: :unprocessable_entity
        raise ActiveRecord::Rollback
      end
    end

  rescue => e
    Rails.logger.error "TransactionsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def destroy
    if @entry.split_child?
      render json: { error: "validation_failed", message: "Split child transactions cannot be deleted individually." }, status: :unprocessable_entity
      return
    end

    @entry.destroy!
    @entry.sync_account_later

    render json: {
      message: "Transaction deleted successfully"
    }, status: :ok

  rescue => e
    Rails.logger.error "TransactionsController#destroy error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def batch_create
    items = batch_items_param
    return if items.nil?
    return render_batch_too_large if items.size > MAX_BATCH_SIZE
    return render_empty_batch if items.empty?

    results = items.each_with_index.map { |raw, idx| process_create_item(raw, idx) }
    log_batch_summary(:batch_create, results)
    render json: build_batch_response(results), status: :multi_status

  rescue => e
    Rails.logger.error "TransactionsController#batch_create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  def batch_update
    items = batch_items_param
    return if items.nil?
    return render_batch_too_large if items.size > MAX_BATCH_SIZE
    return render_empty_batch if items.empty?

    results = items.each_with_index.map { |raw, idx| process_update_item(raw, idx) }
    log_batch_summary(:batch_update, results)
    render json: build_batch_response(results), status: :multi_status

  rescue => e
    Rails.logger.error "TransactionsController#batch_update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  private

    def set_transaction
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      family = current_resource_owner.family
      @transaction = family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(params[:id])
      @entry = @transaction.entry
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Transaction not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def apply_filters(query)
      # Account filtering
      if params[:account_id].present?
        query = query.joins(:entry).where(entries: { account_id: params[:account_id] })
      end

      if params[:account_ids].present?
        account_ids = Array(params[:account_ids])
        query = query.joins(:entry).where(entries: { account_id: account_ids })
      end

      # Category filtering
      if params[:category_id].present?
        query = query.where(category_id: params[:category_id])
      end

      if params[:category_ids].present?
        category_ids = Array(params[:category_ids])
        query = query.where(category_id: category_ids)
      end

      # Merchant filtering
      if params[:merchant_id].present?
        query = query.where(merchant_id: params[:merchant_id])
      end

      if params[:merchant_ids].present?
        merchant_ids = Array(params[:merchant_ids])
        query = query.where(merchant_id: merchant_ids)
      end

      # Date range filtering
      if params[:start_date].present?
        query = query.joins(:entry).where("entries.date >= ?", Date.parse(params[:start_date]))
      end

      if params[:end_date].present?
        query = query.joins(:entry).where("entries.date <= ?", Date.parse(params[:end_date]))
      end

      # Amount filtering
      if params[:min_amount].present?
        min_amount = params[:min_amount].to_f
        query = query.joins(:entry).where("entries.amount >= ?", min_amount)
      end

      if params[:max_amount].present?
        max_amount = params[:max_amount].to_f
        query = query.joins(:entry).where("entries.amount <= ?", max_amount)
      end

      # Tag filtering
      if params[:tag_ids].present?
        tag_ids = Array(params[:tag_ids])
        query = query.joins(:tags).where(tags: { id: tag_ids })
      end

      # Transaction type filtering (income/expense)
      if params[:type].present?
        case params[:type].downcase
        when "income"
          query = query.joins(:entry).where("entries.amount < 0")
        when "expense"
          query = query.joins(:entry).where("entries.amount > 0")
        end
      end

      query
    end

    def apply_search(query)
      search_term = "%#{params[:search]}%"

      query.joins(:entry)
           .left_joins(:merchant)
           .where(
             "entries.name ILIKE ? OR entries.notes ILIKE ? OR merchants.name ILIKE ?",
             search_term, search_term, search_term
           )
end

    def transaction_params
      params.require(:transaction).permit(
        :date, :amount, :name, :description, :notes, :currency,
        :category_id, :merchant_id, :nature, tag_ids: []
      )
    end

    def account_id_param
      params.dig(:transaction, :account_id).presence
    end

    def entry_params_for_create(attrs = transaction_params)
      entry_params = {
        name: attrs[:name] || attrs[:description],
        date: attrs[:date],
        amount: signed_amount_for(attrs[:amount], attrs[:nature]),
        currency: attrs[:currency] || current_resource_owner.family.currency,
        notes: attrs[:notes],
        entryable_type: "Transaction",
        entryable_attributes: {
          category_id: attrs[:category_id],
          merchant_id: attrs[:merchant_id],
          tag_ids: attrs[:tag_ids] || []
        }
      }
      if idempotency_key_requested?
        entry_params[:external_id] = idempotency_external_id
        entry_params[:source] = idempotency_source
      end

      entry_params.compact
    end

    def entry_params_for_update(attrs = transaction_params, entry = @entry)
      entry_params = {
        name: attrs[:name] || attrs[:description],
        date: attrs[:date],
        notes: attrs[:notes],
        entryable_attributes: {
          id: entry.entryable_id,
          category_id: attrs[:category_id],
          merchant_id: attrs[:merchant_id]
          # Note: tag_ids handled separately in update action to distinguish
          # "not provided" from "explicitly set to empty"
        }.compact_blank
      }

      # Only update amount if provided
      if attrs[:amount].present?
        entry_params[:amount] = signed_amount_for(attrs[:amount], attrs[:nature])
      end

      entry_params.compact
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't specify tags".
    def tags_provided?
      params[:transaction].key?(:tag_ids)
    end

    def split_financial_fields_changed?
      params.dig(:transaction, :amount).present? ||
        params.dig(:transaction, :date).present? ||
        params.dig(:transaction, :nature).present?
    end

    def idempotency_key_requested?
      idempotency_external_id.present?
    end

    def idempotency_external_id
      idempotency_param_value(:external_id)
    end

    def idempotency_source
      idempotency_source_param.presence || "api"
    end

    def idempotency_source_param
      idempotency_param_value(:source)
    end

    def idempotency_param_value(key)
      value = params.dig(:transaction, key)
      value.to_s.presence if value.is_a?(String) || value.is_a?(Numeric)
    end

    def existing_idempotent_entry(account)
      account.entries.find_by(
        external_id: idempotency_external_id,
        source: idempotency_source
      )
    end

    def render_existing_idempotent_entry(entry)
      unless entry.entryable.is_a?(Transaction)
        render json: {
          error: "validation_failed",
          message: "External ID already exists for a non-transaction entry",
          errors: [ "External ID already exists for a non-transaction entry" ]
        }, status: :unprocessable_entity
        return
      end

      @entry = entry
      @transaction = entry.transaction
      render :show, status: :ok
    end

    def calculate_signed_amount
      signed_amount_for(transaction_params[:amount], transaction_params[:nature])
    end

    def signed_amount_for(amount, nature)
      amt = amount.to_f
      case nature.to_s.downcase
      when "income", "inflow"
        -amt.abs
      when "expense", "outflow"
        amt.abs
      else
        amt
      end
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
        25  # Default
      end
    end

    def batch_items_param
      raw = params[:transactions]
      unless raw.is_a?(Array) || (raw.respond_to?(:to_a) && raw.respond_to?(:each))
        render json: { error: "validation_failed", message: "transactions is required and must be an array" },
               status: :unprocessable_entity
        return nil
      end
      raw.to_a
    end

    def render_batch_too_large
      render json: { error: "batch_too_large", message: "max #{MAX_BATCH_SIZE} items per request" },
             status: :bad_request
    end

    def render_empty_batch
      render json: { error: "validation_failed", message: "batch must not be empty" },
             status: :unprocessable_entity
    end

    def process_create_item(raw, idx)
      result = { index: idx }
      family = current_resource_owner.family
      raw_params = raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new(raw || {})
      attrs = raw_params.permit(
        :account_id, :date, :amount, :name, :description, :notes, :currency,
        :category_id, :merchant_id, :nature, :client_ref, tag_ids: []
      ).to_h.with_indifferent_access

      result[:client_ref] = attrs[:client_ref] if attrs[:client_ref].present?

      unless attrs[:account_id].present?
        return result.merge(status: "error", error: "validation_failed", errors: [ "Account ID is required" ])
      end

      account = family.accounts.writable_by(current_resource_owner).find_by(id: attrs[:account_id])
      unless account
        return result.merge(status: "error", error: "not_found", errors: [ "Account not found or not writable" ])
      end

      entry = nil
      Entry.transaction do
        entry = account.entries.new(entry_params_for_create(attrs))
        entry.save!
        entry.lock_saved_attributes!
        entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?
      end

      entry.sync_account_later

      txn_json = render_to_string(
        partial: "api/v1/transactions/transaction",
        formats: [ :json ],
        locals: { transaction: entry.transaction }
      )
      result.merge(status: "created", transaction: JSON.parse(txn_json))

    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn "batch_create item #{idx} invalid: #{e.message}"
      result.merge(status: "error", error: "validation_failed", errors: e.record.errors.full_messages)
    rescue => e
      Rails.logger.error "batch_create item #{idx} error: #{e.message}"
      result.merge(status: "error", error: "internal_server_error", errors: [ e.message ])
    end

    def process_update_item(raw, idx)
      result = { index: idx }
      family = current_resource_owner.family
      raw_params = raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new(raw || {})
      attrs = raw_params.permit(
        :id, :date, :amount, :name, :description, :notes, :currency,
        :category_id, :merchant_id, :nature, :client_ref, tag_ids: []
      ).to_h.with_indifferent_access

      result[:client_ref] = attrs[:client_ref] if attrs[:client_ref].present?

      unless attrs[:id].present?
        return result.merge(status: "error", error: "validation_failed", errors: [ "Transaction id is required" ])
      end

      transaction = family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find_by(id: attrs[:id])
      unless transaction
        return result.merge(status: "error", error: "not_found", errors: [ "Transaction not found" ])
      end

      entry = transaction.entry

      if entry.split_child?
        return result.merge(status: "error", error: "validation_failed",
          errors: [ "Split child transactions cannot be edited directly. Use the split editor." ])
      end

      financial_changed = attrs[:amount].present? || attrs[:date].present? || attrs[:nature].present?
      if entry.split_parent? && financial_changed
        return result.merge(status: "error", error: "validation_failed",
          errors: [ "Split parent amount, date, and type cannot be changed directly. Use the split editor." ])
      end

      tags_provided = raw_params.respond_to?(:key?) && (raw_params.key?(:tag_ids) || raw_params.key?("tag_ids"))

      Entry.transaction do
        entry.update!(entry_params_for_update(attrs, entry))

        if tags_provided
          entry.transaction.tag_ids = attrs[:tag_ids] || []
          entry.transaction.save!
          entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?
        end

        entry.lock_saved_attributes!
      end

      entry.sync_account_later

      txn_json = render_to_string(
        partial: "api/v1/transactions/transaction",
        formats: [ :json ],
        locals: { transaction: entry.transaction.reload }
      )
      result.merge(status: "updated", transaction: JSON.parse(txn_json))

    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn "batch_update item #{idx} invalid: #{e.message}"
      result.merge(status: "error", error: "validation_failed", errors: e.record.errors.full_messages)
    rescue => e
      Rails.logger.error "batch_update item #{idx} error: #{e.message}"
      result.merge(status: "error", error: "internal_server_error", errors: [ e.message ])
    end

    def build_batch_response(results)
      succeeded = results.count { |r| %w[created updated].include?(r[:status]) }
      failed = results.size - succeeded
      {
        results: results,
        summary: { total: results.size, succeeded: succeeded, failed: failed }
      }
    end

    def log_batch_summary(action, results)
      succeeded = results.count { |r| %w[created updated].include?(r[:status]) }
      failed = results.size - succeeded
      Rails.logger.info "#{action}: #{results.size} items, #{succeeded} succeeded, #{failed} failed"
    end
end
