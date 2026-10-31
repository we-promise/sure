class TransferMatchesController < ApplicationController
  before_action :set_entry

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

    redirect_back_or_to transactions_path, notice: t(".success")
  rescue ActiveRecord::RecordInvalid => e
    alert = already_matched?(e.record) ? t(".already_matched") : e.record.errors.full_messages.to_sentence
    redirect_back_or_to transactions_path, alert: alert
  rescue ActiveRecord::RecordNotUnique
    # A concurrent sync matched one of the two transactions first; the unique
    # transfer indexes rejected this insert.
    redirect_back_or_to transactions_path, alert: t(".already_matched")
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

    # One of the two transactions already belongs to another transfer, in either role.
    def already_matched?(record)
      record.is_a?(Transfer) &&
        (record.errors.of_kind?(:inflow_transaction_id, :taken) || record.errors.of_kind?(:outflow_transaction_id, :taken))
    end

    def transfer_match_params
      params.require(:transfer_match).permit(:method, :matched_entry_id, :target_account_id)
    end

    def resolve_target_account
      if transfer_match_params[:method] == "new"
        accessible_accounts.find(transfer_match_params[:target_account_id])
      else
        Current.accessible_entries.find(transfer_match_params[:matched_entry_id]).account
      end
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
        target_transaction = Current.accessible_entries.find(transfer_match_params[:matched_entry_id])

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.negative? ? @entry.transaction : target_transaction.transaction,
          outflow_transaction: @entry.amount.negative? ? target_transaction.transaction : @entry.transaction
        )
        transfer.status = "confirmed"
        transfer
      end
    end
end
