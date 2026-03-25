class AccountSharingsController < ApplicationController
  before_action :set_account

  def show
    @family_members = Current.family.users.where.not(id: @account.owner_id).where(active: true)
    @account_shares = @account.account_shares.includes(:user).index_by(&:user_id)
  end

  def update
    # Non-owners can update their own include_in_finances preference
    if !@account.owned_by?(Current.user) && params[:update_finance_inclusion].present?
      share = @account.account_shares.find_by!(user: Current.user)
      include_value = params.permit(:include_in_finances)[:include_in_finances]
      share.update!(include_in_finances: ActiveModel::Type::Boolean.new.cast(include_value))
      redirect_back_or_to account_path(@account), notice: t("account_sharings.update.finance_toggle_success")
      return
    end

    unless @account.owned_by?(Current.user)
      redirect_to account_path(@account), alert: t("account_sharings.update.not_owner")
      return
    end

    eligible_members = Current.family.users.where.not(id: @account.owner_id).where(active: true)

    AccountShare.transaction do
      sharing_members_params.each do |member_params|
        user = eligible_members.find_by(id: member_params[:user_id])
        next unless user

        share = @account.account_shares.find_by(user: user)

        if ActiveModel::Type::Boolean.new.cast(member_params[:shared])
          permission = AccountShare::PERMISSIONS.include?(member_params[:permission]) ? member_params[:permission] : (share&.permission || "read_only")
          if share
            share.update!(permission: permission)
          else
            @account.account_shares.create!(user: user, permission: permission, include_in_finances: true)
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

    def sharing_members_params
      return [] unless params.dig(:sharing, :members)

      params.require(:sharing).permit(
        members: [ :user_id, :shared, :permission ]
      )[:members]&.values || []
    end
end
