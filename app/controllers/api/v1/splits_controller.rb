# frozen_string_literal: true

# Splits a transaction into child transactions that sum to it.
#
# The model has supported this since splits shipped (`Entry#split!` /
# `Entry#unsplit!`), and the web UI exposes it, but the API did not -- and
# `Api::V1::TransactionsController` actively refuses split edits with "Use the
# split editor", which an API consumer cannot reach. These actions close that
# gap using the same model calls the UI makes.
class Api::V1::SplitsController < Api::V1::BaseController
  AlreadySplit = Class.new(StandardError)
  NotSplit = Class.new(StandardError)

  # entries.amount is decimal(19,4). Children are rounded independently on
  # assignment, so raw values that sum to the parent can persist as a total
  # that does not: 33.33335 + 66.66665 becomes 33.3334 + 66.6667 = 100.0001.
  AMOUNT_SCALE = 4
  before_action :ensure_read_scope, only: [ :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_transaction
  before_action :resolve_to_parent
  before_action :ensure_account_write_permission, only: [ :create, :update, :destroy ]

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

    # Explicit transaction + lock!, NOT Entry#with_lock: on Rails 8.1 the
    # with_lock form silently discards the whole split -- no children, no
    # exception. Verified against real data before relying on this.
    Entry.transaction do
      @entry.lock!
      # Re-check inside the lock: two concurrent POSTs can both clear the
      # check above, and split! validates only its own amounts, so both sets
      # of children would be inserted and the transaction counted twice.
      raise AlreadySplit if @entry.split_parent?

      @entry.split!(splits)
    end
    @entry.sync_account_later
    @entry.reload

    render :show, status: :created
  rescue AlreadySplit
    render_unprocessable("Transaction cannot be split", [ "Transaction is already split" ])
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
      @entry.lock!
      # The split_parent? test above runs before the lock, so a concurrent
      # DELETE can unsplit in between; without this the replacement would
      # resurrect a split the other caller just removed.
      raise NotSplit unless @entry.split_parent?

      @entry.unsplit!
      @entry.split!(splits)
    end
    @entry.sync_account_later
    @entry.reload

    render :show
  rescue NotSplit
    render_not_split
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e.message)
  end

  # DELETE /api/v1/transactions/:transaction_id/split
  def destroy
    return render_not_split unless @entry.split_parent?

    Entry.transaction do
      @entry.lock!
      raise NotSplit unless @entry.split_parent?

      @entry.unsplit!
    end
    @entry.sync_account_later

    head :no_content
  rescue NotSplit
    render_not_split
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

    # The token scope says what the KEY may do; this says what its owner may do
    # to this account. `Account.accessible_by` admits every share, read-only
    # ones included, so without this a read-only share could rewrite someone
    # else's transaction. SplitsController enforces the same thing through
    # require_account_permission!.
    def ensure_account_write_permission
      return if performed?
      return if @entry.account.permission_for(current_resource_owner).in?([ :owner, :full_control ])

      render json: {
        error: "forbidden",
        message: "You do not have write access to this account"
      }, status: :forbidden
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
        category_id = s[:category_id].presence
        if category_id && !family_category_ids.include?(category_id)
          render_unprocessable("Unknown category: #{category_id}")
          return nil
        end

        {
          # Documented as optional, defaulting to the parent's name; Entry
          # validates presence, so apply the default rather than 422 on it.
          name: s[:name].presence || @entry.name,
          amount: BigDecimal(s[:amount].to_s).round(AMOUNT_SCALE),
          category_id: category_id,
          excluded: s[:excluded]
        }
      end
    rescue ArgumentError, TypeError
      render_unprocessable("each split requires a numeric amount")
      nil
    end

    # belongs_to :category is unscoped, so a known UUID from another family
    # would be accepted and then serialized back to the caller.
    def family_category_ids
      @family_category_ids ||= current_resource_owner.family.categories.pluck(:id).to_set
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
