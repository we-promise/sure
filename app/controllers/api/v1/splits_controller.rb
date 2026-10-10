# frozen_string_literal: true

# Splits a transaction into child transactions that sum to it.
#
# The model has supported this since splits shipped (`Entry#split!` /
# `Entry#unsplit!`), and the web UI exposes it, but the API did not -- and
# `Api::V1::TransactionsController` actively refuses split edits with "Use the
# split editor", which an API consumer cannot reach. These actions close that
# gap using the same model calls the UI makes.
class Api::V1::SplitsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: [ :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_transaction
  before_action :resolve_to_parent

  # GET /api/v1/transactions/:transaction_id/split
  def show
    return render_not_split unless @entry.split_parent?

    render :show
  end

  # POST /api/v1/transactions/:transaction_id/split
  def create
    unless @transaction.splittable?
      return render_unprocessable("Transaction cannot be split", [ not_splittable_reason ])
    end

    splits = build_splits
    return if performed?

    @entry.split!(splits)
    @entry.sync_account_later
    @entry.reload

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e.message)
  end

  # PATCH/PUT /api/v1/transactions/:transaction_id/split
  #
  # Replaces the existing children. They are destroyed and recreated, exactly as
  # the web UI does it, so anything set on a child afterwards -- a category, an
  # exclusion -- is NOT carried over. Send the full set you want.
  def update
    return render_not_split unless @entry.split_parent?

    splits = build_splits
    return if performed?

    Entry.transaction do
      @entry.unsplit!
      @entry.split!(splits)
    end
    @entry.sync_account_later
    @entry.reload

    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e.message)
  end

  # DELETE /api/v1/transactions/:transaction_id/split
  def destroy
    return render_not_split unless @entry.split_parent?

    @entry.unsplit!
    @entry.sync_account_later

    head :no_content
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e.message)
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_transaction
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:transaction_id])

      family = current_resource_owner.family
      @transaction = family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(params[:transaction_id])
      @entry = @transaction.entry
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Transaction not found"
      }, status: :not_found
    end

    # Addressing a child by id resolves to its parent, so a caller holding any
    # id from the split can operate on it. Mirrors the web controller.
    def resolve_to_parent
      return if performed?
      return unless @entry&.split_child?

      @entry = @entry.parent_entry
      @transaction = @entry.transaction
    end

    # Amounts use the SAME sign convention as the parent's `amount`, which is
    # what `GET /api/v1/transactions/:id` returns. The web controller negates
    # what its form submits; that is a property of the form, not of the model,
    # and an API that flipped the sign of its input would contradict the
    # transaction endpoints it sits beside.
    def build_splits
      raw = params.dig(:split, :splits)
      raw = raw.values if raw.respond_to?(:values)

      unless raw.is_a?(Array) && raw.any?
        render_unprocessable("splits must be a non-empty array")
        return nil
      end

      raw.map do |s|
        s = s.permit(:name, :amount, :category_id, :excluded) if s.respond_to?(:permit)
        {
          name: s[:name].presence,
          amount: BigDecimal(s[:amount].to_s),
          category_id: s[:category_id].presence,
          excluded: s[:excluded]
        }
      end
    rescue ArgumentError, TypeError
      render_unprocessable("each split requires a numeric amount")
      nil
    end

    def not_splittable_reason
      return "Transaction is part of a transfer" if @transaction.transfer?
      return "Transaction is already split" if @entry.split_parent?
      return "Transaction is pending" if @transaction.pending?
      return "Transaction is excluded" if @entry.excluded?

      "Transaction is not splittable"
    end

    def render_not_split
      render json: {
        error: "not_found",
        message: "Transaction is not split"
      }, status: :not_found
    end

    def render_unprocessable(message, errors = nil)
      render json: {
        error: "validation_failed",
        message: message,
        errors: errors || [ message ]
      }, status: :unprocessable_entity
    end
end
