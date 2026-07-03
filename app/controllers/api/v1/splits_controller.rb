# frozen_string_literal: true

class Api::V1::SplitsController < Api::V1::BaseController
  # Responses reuse the transactions JSON views (show / _transaction). Add that
  # view path to the lookup prefixes so partials referenced relatively resolve
  # to api/v1/transactions/* rather than this controller's own (nonexistent) views.
  def self._prefixes
    @_prefixes ||= super + [ "api/v1/transactions" ]
  end

  # Splitting mutates the ledger, so every action requires write scope.
  before_action :ensure_write_scope
  before_action :set_entry

  # POST /api/v1/transactions/:transaction_id/split
  #
  # Splits a transaction into child transactions, each with its own category,
  # name, tags-free amount, and optional exclusion. Mirrors the web split editor
  # (SplitsController) so receipt line items can be applied programmatically.
  #
  # Body:
  #   { "split": { "splits": [
  #       { "name": "Groceries", "amount": -42.10, "category_id": "<uuid>" },
  #       { "name": "Household", "amount": -13.94, "category_id": "<uuid>", "excluded": false }
  #   ] } }
  #
  # Amounts are signed in the same convention as the transaction's amount
  # (expense positive, income negative) and must sum to the parent amount.
  def create
    unless @entry.transaction.splittable?
      return render_validation_error("Transaction cannot be split (it is pending, a transfer, excluded, or already split)")
    end

    @entry.split!(build_splits)
    @entry.sync_account_later

    @transaction = @entry.transaction
    render "api/v1/transactions/show", status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.message)
  end

  # PATCH/PUT /api/v1/transactions/:transaction_id/split
  #
  # Replaces the existing splits on a split parent. Accepts either the parent
  # transaction id or any child transaction id (resolves to the parent).
  def update
    resolve_to_parent!

    unless @entry.split_parent?
      return render_validation_error("Transaction is not split")
    end

    Entry.transaction do
      @entry.unsplit!
      @entry.split!(build_splits)
    end
    @entry.sync_account_later

    @transaction = @entry.transaction
    render "api/v1/transactions/show"
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.message)
  end

  # DELETE /api/v1/transactions/:transaction_id/split
  #
  # Removes all split children and restores the parent transaction.
  def destroy
    resolve_to_parent!

    unless @entry.split_parent?
      return render_validation_error("Transaction is not split")
    end

    @entry.unsplit!
    @entry.sync_account_later

    @transaction = @entry.transaction
    render "api/v1/transactions/show"
  end

  private

    def set_entry
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:transaction_id])

      family = current_resource_owner.family
      transaction = family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(params[:transaction_id])
      @entry = transaction.entry

      unless @entry.account.permission_for(current_resource_owner).in?(%i[owner full_control])
        return render_forbidden
      end
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Transaction not found" }, status: :not_found
    end

    def resolve_to_parent!
      @entry = @entry.parent_entry if @entry.split_child?
    end

    # Normalizes the splits payload into the hash shape Entry#split! expects.
    # Unlike the web form (which passes positive amounts and negates them),
    # the API takes amounts already signed to match the parent transaction.
    # Required fields are validated before coercion so a malformed payload
    # surfaces as a 422 rather than a 500.
    def build_splits
      raw = split_params[:splits]
      raw = raw.values if raw.respond_to?(:values)
      raw = Array(raw)

      invalid_split!("At least one split is required") if raw.empty?

      raw.map do |s|
        invalid_split!("Each split requires an amount") if s[:amount].blank?

        {
          name: s[:name],
          amount: s[:amount].to_d,
          category_id: s[:category_id].presence,
          excluded: s[:excluded]
        }
      end
    end

    # Adds a validation error to the parent entry and raises so the action's
    # RecordInvalid rescue renders the standard 422 response.
    def invalid_split!(message)
      @entry.errors.add(:base, message)
      raise ActiveRecord::RecordInvalid.new(@entry)
    end

    def split_params
      params.require(:split).permit(splits: [ :name, :amount, :category_id, :excluded ])
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def render_forbidden
      render json: { error: "forbidden", message: "You do not have permission to modify this transaction" }, status: :forbidden
    end
end
