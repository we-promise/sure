# frozen_string_literal: true

module Admin
  class UsersController < Admin::BaseController
    before_action :set_user, only: %i[update]

    def index
      authorize User
      @users = policy_scope(User)
        .left_joins(family: :subscription)
        .includes(family: :subscription)
        .order(Arel.sql("subscriptions.trial_ends_at IS NULL, subscriptions.trial_ends_at ASC, users.email ASC"))
    end

    def update
      authorize @user

      if @user.update(user_params)
        Rails.logger.info(
          "[Admin::Users] Role changed - " \
          "by_user_id=#{Current.user.id} " \
          "target_user_id=#{@user.id} " \
          "new_role=#{@user.role}"
        )
        redirect_to admin_users_path, notice: t(".success")
      else
        redirect_to admin_users_path, alert: t(".failure")
      end
    end

    private

      def set_user
        @user = User.find(params[:id])
      end

      def user_params
        params.require(:user).permit(:role)
      end
  end
end
