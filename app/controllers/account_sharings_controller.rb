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

    # The owner's own percentage and every member's change persist together or not at all.
    AccountShare.transaction do
      @account.update!(ownership_percentage: params[:owner_ownership_percentage]) if params.key?(:owner_ownership_percentage)

      sharing_members_params.each do |member_params|
        user = eligible_members.find_by(id: member_params[:user_id])
        next unless user

        share = @account.account_shares.find_by(user: user)

        if ActiveModel::Type::Boolean.new.cast(member_params[:shared])
          permission = AccountShare::PERMISSIONS.include?(member_params[:permission]) ? member_params[:permission] : (share&.permission || "read_only")
          attrs = { permission: permission }
          attrs[:ownership_percentage] = member_params[:ownership_percentage] if member_params.key?(:ownership_percentage)

          if share
            share.update!(attrs)
          else
            @account.account_shares.create!(attrs.merge(user: user, include_in_finances: true))
          end
        elsif share
          share.destroy!
        end
      end
    end

    redirect_back_or_to accounts_path, notice: t("account_sharings.update.success")
  rescue ActiveRecord::RecordInvalid => e
    redirect_back_or_to account_path(@account), alert: e.record.errors.full_messages.to_sentence
  end

  private

    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
    end

    def sharing_members_params
      return [] unless params.dig(:sharing, :members)

      params.require(:sharing).permit(
        members: [ :user_id, :shared, :permission, :ownership_percentage ]
      )[:members]&.values || []
    end
end
