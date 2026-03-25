class TransferMatchesController < ApplicationController
  before_action :set_entry

  def new
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
    @transfer_match_candidates = @entry.transaction.transfer_match_candidates
  end

  def create
    permission = @entry.account.permission_for(Current.user)
    unless permission.in?([ :owner, :full_control ])
      redirect_back_or_to transactions_path, alert: t("accounts.not_authorized")
      return
    end

    target_account = resolve_target_account
    unless target_account.permission_for(Current.user).in?([ :owner, :full_control ])
      redirect_back_or_to transactions_path, alert: t("accounts.not_authorized")
      return
    end

    @transfer = build_transfer
    Transfer.transaction do
      @transfer.save!

      # Use DESTINATION (inflow) account for kind, matching Transfer::Creator logic
      destination_account = @transfer.inflow_transaction.entry.account
      outflow_kind = Transfer.kind_for_account(destination_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution"
        category = destination_account.family.investment_contributions_category
        outflow_attrs[:category] = category if category.present? && @transfer.outflow_transaction.category_id.blank?
      end

      @transfer.outflow_transaction.update!(outflow_attrs)
      @transfer.inflow_transaction.update!(kind: "funds_movement")
    end

    @transfer.sync_account_later

    redirect_back_or_to transactions_path, notice: "Transfer created"
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
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
