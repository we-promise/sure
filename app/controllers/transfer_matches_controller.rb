class TransferMatchesController < ApplicationController
  before_action :set_entry

  def new
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
    @transfer_match_candidates = @entry.transaction.transfer_match_candidates
  end

  def create
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    target_account = resolve_target_account
    return unless require_account_permission!(target_account, redirect_path: transactions_path)

    if loan_payment_split_confirmation_required?(target_account)
      set_form_state
      @loan_payment_split_preview = loan_payment_split_preview(target_account)
      render :new, status: :unprocessable_entity
      return
    end

    Transfer.transaction do
      @transfer = build_transfer(target_account)
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

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    def set_form_state
      @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
      @transfer_match_candidates = @entry.transaction.transfer_match_candidates
    end

    def transfer_match_params
      params.require(:transfer_match).permit(:method, :matched_entry_id, :target_account_id, :loan_payment_split_action)
    end

    def resolve_target_account
      if transfer_match_params[:method] == "new"
        accessible_accounts.find(transfer_match_params[:target_account_id])
      else
        Current.accessible_entries.find(transfer_match_params[:matched_entry_id]).account
      end
    end

    def build_transfer(target_account)
      if accepted_new_annuity_loan_payment?(target_account)
        return build_split_annuity_loan_transfer(target_account)
      end

      if transfer_match_params[:method] == "new"
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

    def accepted_new_annuity_loan_payment?(target_account)
      transfer_match_params[:method] == "new" &&
        transfer_match_params[:loan_payment_split_action] == "accept" &&
        @entry.amount.positive? &&
        target_account.loan? &&
        target_account.loan.annuity_enabled?
    end

    def loan_payment_split_confirmation_required?(target_account)
      return false if transfer_match_params[:loan_payment_split_action].present?
      return false unless @entry.amount.positive? && target_account.loan? && target_account.loan.annuity_enabled?

      loan_payment_split_preview(target_account)&.matched?
    end

    def loan_payment_split_preview(target_account)
      return nil unless target_account.loan? && target_account.loan.annuity_enabled?

      Loan::PaymentSplitter.new(target_account.loan).split(
        payment_date: @entry.date,
        amount: @entry.amount
      )
    end

    def build_split_annuity_loan_transfer(loan_account)
      split = Loan::PaymentSplitter.new(loan_account.loan).split(
        payment_date: @entry.date,
        amount: @entry.amount
      )

      return build_transfer_without_split(loan_account) unless split.matched?

      split_parent_into_loan_payment!(loan_account, split)
      principal_entry = @entry.child_entries.find_by!(name: "Principal for #{loan_account.name}")

      loan_transaction = Transaction.new(
        kind: "funds_movement",
        extra: loan_payment_extra(split),
        entry: loan_account.entries.build(
          amount: (split.principal + split.extra_principal) * -1,
          currency: loan_account.currency,
          date: @entry.date,
          name: "Payment from #{@entry.account.name}",
          user_modified: true
        )
      )

      Transfer.new(
        inflow_transaction: loan_transaction,
        outflow_transaction: principal_entry.transaction,
        status: "confirmed"
      )
    end

    def split_parent_into_loan_payment!(loan_account, split)
      principal_amount = split.principal + split.extra_principal

      @entry.split!([
        {
          name: "Principal for #{loan_account.name}",
          amount: principal_amount,
          category_id: @entry.transaction.category_id,
          excluded: false
        },
        {
          name: "Interest for #{loan_account.name}",
          amount: split.interest,
          category_id: @entry.transaction.category_id,
          excluded: false
        }
      ])

      @entry.child_entries.find_by!(name: "Principal for #{loan_account.name}").transaction.update!(
        extra: loan_payment_extra(split)
      )
      @entry.child_entries.find_by!(name: "Interest for #{loan_account.name}").transaction.update!(
        kind: "standard",
        extra: loan_payment_extra(split)
      )
    end

    def build_transfer_without_split(target_account)
      missing_transaction = Transaction.new(
        entry: target_account.entries.build(
          amount: @entry.amount * -1,
          currency: @entry.currency,
          date: @entry.date,
          name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
          user_modified: true,
        )
      )

      Transfer.new(
        inflow_transaction: @entry.amount.positive? ? missing_transaction : @entry.transaction,
        outflow_transaction: @entry.amount.positive? ? @entry.transaction : missing_transaction,
        status: "confirmed"
      )
    end

    def loan_payment_extra(split)
      {
        "loan_payment_split" => {
          "period_number" => split.period_number,
          "due_date" => split.due_date.to_s,
          "interest" => split.interest.to_s,
          "principal" => split.principal.to_s,
          "extra_principal" => split.extra_principal.to_s,
          "variance" => split.variance.to_s,
          "scheduled_payment" => split.scheduled_payment.to_s
        }
      }
    end
end
