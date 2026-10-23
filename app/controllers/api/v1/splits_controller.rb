# frozen_string_literal: true

# Splits a transaction into child transactions that sum to it.
#
# The model has supported this since splits shipped (`Entry#split!` /
# `Entry#unsplit!`), and the web UI exposes it, but the API did not -- and
# `Api::V1::TransactionsController` actively refuses split edits with "Use the
# split editor", which an API consumer cannot reach. These actions close that
# gap using the same model calls the UI makes.
class Api::V1::SplitsController < Api::V1::BaseController
  include Api::V1::TransactionLookup

  NotSplittable = Class.new(StandardError)
  NotSplit = Class.new(StandardError)

  # entries.amount is decimal(19,4). Children are rounded independently on
  # assignment, so raw values that sum to the parent can persist as a total
  # that does not: 33.33335 + 66.66665 becomes 33.3334 + 66.6667 = 100.0001.
  AMOUNT_SCALE = 4
  # 15 integer digits. Oversized amounts that cancel out pass split!'s sum
  # check and then overflow the column, which surfaces as a 500.
  AMOUNT_LIMIT = BigDecimal(10)**15
  before_action :ensure_read_scope, only: [ :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_transaction
  before_action :resolve_to_parent
  before_action :ensure_account_write_permission, only: [ :create, :update, :destroy ]

  # GET /api/v1/transactions/:transaction_id/split
  def show
    return render_not_split unless @entry.split_parent?

    render_split
  end

  # POST /api/v1/transactions/:transaction_id/split
  def create
    unless @transaction.splittable?
      return render_unprocessable("Transaction cannot be split", [ not_splittable_reason ])
    end

    splits = build_splits
    return if performed?

    # Two concurrent POSTs can both clear the check above; split_once! locks
    # the parent and re-checks, so only one set of children is inserted.
    raise NotSplittable unless @entry.split_once!(splits)
    @entry.sync_account_later
    @entry.reload

    render_split status: :created
  rescue NotSplittable
    # Reload so the reason reflects what the other caller or a sync did in the meantime
    # (split, excluded, pending, transfer), not the state checked before the lock.
    @entry.reload
    @transaction.reload
    render_unprocessable("Transaction cannot be split", [ not_splittable_reason ])
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

    # The split_parent? test above runs before the lock, so a concurrent DELETE can unsplit in
    # between; resplit! re-checks under the lock instead of resurrecting the split.
    raise NotSplit unless @entry.resplit!(splits)
    @entry.sync_account_later
    @entry.reload

    render_split
  rescue NotSplit
    render_not_split
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e.message)
  end

  # DELETE /api/v1/transactions/:transaction_id/split
  def destroy
    return render_not_split unless @entry.split_parent?

    raise NotSplit unless @entry.unsplit_once!
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
      load_accessible_transaction(params[:transaction_id])
    end

    # Loaded from the Transaction side because that is the direction the
    # transaction partial reads in (transaction.entry.account). Preloading
    # child_entries.entryable does not help: the polymorphic pair has no
    # inverse, so each child would reload its entry and account.
    def render_split(status: :ok)
      @children = Transaction
        .joins(:entry)
        .where(entries: { parent_entry_id: @entry.id })
        .preload(
          { entry: :account },
          :category, :merchant, :tags,
          transfer_as_outflow: { inflow_transaction: { entry: :account } },
          transfer_as_inflow: { outflow_transaction: { entry: :account } }
        )
        .order("entries.created_at")

      render :show, status: status
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
        unless s.respond_to?(:permit)
          render_unprocessable("each split must be an object")
          return nil
        end

        unless s[:tag_ids].nil? || (s[:tag_ids].is_a?(Array) && s[:tag_ids].all?(String))
          render_unprocessable("tag_ids must be an array of tag ids")
          return nil
        end
        # permit would silently drop a non-scalar id, storing the child without it.
        %i[category_id merchant_id].each do |key|
          next if s[key].nil? || s[key].is_a?(String)

          render_unprocessable("#{key} must be an id")
          return nil
        end

        s = s.permit(:name, :amount, :category_id, :merchant_id, :excluded, tag_ids: [])
        references = { category_id: s[:category_id], merchant_id: s[:merchant_id], tag_ids: s[:tag_ids] }

        unknown = split_references.unknown(**references)
        if unknown.any?
          kind, id = unknown.first
          render_unprocessable("Unknown #{kind}: #{id}")
          return nil
        end

        # Round before the range check: 999999999999999.99995 is under the
        # limit as sent and at it once rounded.
        amount = BigDecimal(s[:amount].to_s)
        amount = amount.round(AMOUNT_SCALE) if amount.finite?
        unless amount.finite? && amount.abs < AMOUNT_LIMIT
          render_unprocessable("split amount is out of range")
          return nil
        end

        {
          # Documented as optional, defaulting to the parent's name; Entry
          # validates presence, so apply the default rather than 422 on it.
          name: s[:name].presence || @entry.name,
          amount: amount,
          excluded: s[:excluded],
          # Nothing is dropped here (unknown ids were rejected above); scope only normalizes.
          # Without a merchant_id the child keeps the parent's merchant (Entry#split!).
          **split_references.scope(**references)
        }
      end
    rescue ArgumentError, TypeError
      render_unprocessable("each split requires a numeric amount")
      nil
    end

    # Transaction's belongs_to :category and :merchant are unscoped, so a known UUID from another
    # family would be accepted and then serialized back to the caller. The same rules as the web
    # split editor apply: family categories and tags, and any merchant the user can see.
    def split_references
      @split_references ||= Entry::SplitReferences.for_user(current_resource_owner.family, current_resource_owner)
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
