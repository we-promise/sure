class TransferMatchesController < ApplicationController
  before_action :set_entry
  before_action :refuse_split_parent, only: %i[new create]

  def new
    # Preloaded for the logo selects, which call Account#logo_url per option.
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
      .includes(:account_providers, logo_attachment: :blob)
    @candidate_entries = writable_candidate_entries
  end

  def create
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    target_account = resolve_target_account
    return unless require_account_permission!(target_account, redirect_path: transactions_path)

    @transfer = build_transfer
    Transfer.transaction do
      @transfer.save!
      @transfer.confirm!
    end

    @transfer.sync_account_later

    # A new counterpart for an outflow is a deposit booked on the target
    # account, which can resolve its transfer pledge. Matching two existing
    # entries books nothing new.
    if transfer_match_params[:method] == "new" && @entry.amount.positive?
      GoalPledge::Reconciler.run_after_commit(@transfer.inflow_transaction.entry)
    end

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  # "Not a transfer" on the list's transfer hint.
  def destroy
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    Current.family.dismiss_transfer_hint!(@entry.transaction, user: Current.user)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(helpers.dom_id(@entry.transaction, :transfer_hint)) }
      format.html { redirect_back_or_to transactions_path }
    end
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    # A split parent's amount is already in its parts, so matching it would move
    # the other account's balance on top of a matched part.
    def refuse_split_parent
      return unless @entry.split_parent? || matched_entry&.split_parent?

      redirect_back_or_to transactions_path, alert: t("transfer_matches.split_parent")
    end

    # Counterpart entries of the family-wide candidates, in candidate order and
    # limited to accounts the user can write to (create would reject the others
    # anyway).
    def writable_candidate_entries
      counterpart_ids = @entry.transaction.transfer_match_candidates.map do |candidate|
        @entry.amount.negative? ? candidate.outflow_transaction_id : candidate.inflow_transaction_id
      end

      entries_by_transaction_id = Entry
        .where(entryable_type: "Transaction", entryable_id: counterpart_ids, account_id: @accounts.map(&:id))
        .includes(account: [ :account_providers, { logo_attachment: :blob } ])
        .index_by(&:entryable_id)

      counterpart_ids.filter_map { |id| entries_by_transaction_id[id] }
    end

    def transfer_match_params
      params.require(:transfer_match).permit(:method, :matched_entry_id, :target_account_id)
    end

    def resolve_target_account
      if transfer_match_params[:method] == "new"
        accessible_accounts.find(transfer_match_params[:target_account_id])
      else
        matched_entry.account
      end
    end

    def matched_entry
      return if action_name != "create" || transfer_match_params[:method] == "new"

      @matched_entry ||= Current.accessible_entries.find(transfer_match_params[:matched_entry_id])
    end

    def build_transfer
      if transfer_match_params[:method] == "new"
        target_account = accessible_accounts.find(transfer_match_params[:target_account_id])

        missing_transaction = Transaction.new(
          entry: target_account.entries.build(
            amount: @entry.amount * -1,
            currency: @entry.currency,
            date: @entry.date,
            name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
            user_modified: true,
          )
        )

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.positive? ? missing_transaction : @entry.transaction,
          outflow_transaction: @entry.amount.positive? ? @entry.transaction : missing_transaction
        )
        transfer.status = "confirmed"
        transfer
      else
        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.negative? ? @entry.transaction : matched_entry.transaction,
          outflow_transaction: @entry.amount.negative? ? matched_entry.transaction : @entry.transaction
        )
        transfer.status = "confirmed"
        transfer
      end
    end
end
