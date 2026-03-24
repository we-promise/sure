class AccountSharingsController < ApplicationController
  before_action :set_account

  def show
    @family_members = Current.family.users.where.not(id: @account.owner_id).where(active: true)
    @account_shares = @account.account_shares.includes(:user).index_by(&:user_id)
  end

  def update
    # Non-owners can only toggle their own include_in_finances
    if !@account.owned_by?(Current.user) && params[:toggle_finance_inclusion].present?
      share = @account.account_shares.find_by!(user: Current.user)
      share.update!(include_in_finances: !share.include_in_finances)
      redirect_back_or_to account_path(@account), notice: t("account_sharings.update.finance_toggle_success")
      return
    end

    unless @account.owned_by?(Current.user)
      redirect_to account_path(@account), alert: t("account_sharings.update.not_owner")
      return
    end

    members_params = params.dig(:sharing, :members)&.values || []

    AccountShare.transaction do
      members_params.each do |member_params|
        user = Current.family.users.find(member_params[:user_id])
        share = @account.account_shares.find_by(user: user)

        if ActiveModel::Type::Boolean.new.cast(member_params[:shared])
          if share
            share.update!(
              permission: member_params[:permission] || share.permission
            )
          else
            @account.account_shares.create!(
              user: user,
              permission: member_params[:permission] || "read_only",
              include_in_finances: true
            )
          end
        elsif share
          share.destroy!
        end
      end
    end

    redirect_back_or_to accounts_path, notice: t("account_sharings.update.success")
  end

  private

    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
    end
end
