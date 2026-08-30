# Review and removal of the duplicate merchant-side card transactions that were
# imported before the twin filter landed.
class Accounts::CardTwinCleanupsController < ApplicationController
  before_action :set_account

  def show
    @candidates = candidates
  end

  def create
    # The form is not trusted: the candidate set is re-derived here and the
    # submitted ids are only ever used to narrow it.
    selected_ids = Array(params.dig(:card_twin_cleanup, :entry_ids)).map(&:to_s).to_set
    removable = candidates.select { |candidate| selected_ids.include?(candidate.entry.id) }

    ApplicationRecord.transaction do
      removable.each(&:remove!)
    end

    @account.sync_later if removable.any?

    redirect_to account_path(@account), notice: t(".success", count: removable.size)
  end

  private
    def set_account
      @account = Current.family.accounts.writable_by(Current.user).find(params[:account_id])
    end

    def candidates
      @candidates ||= EnableBankingAccount
        .joins(:account_provider)
        .where(account_providers: { account_id: @account.id })
        .flat_map { |enable_banking_account| enable_banking_account.card_twin_candidates.to_a }
    end
end
