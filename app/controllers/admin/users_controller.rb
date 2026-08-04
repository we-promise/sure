# frozen_string_literal: true

module Admin
  class UsersController < Admin::BaseController
    before_action :set_user, only: %i[update destroy]

    def index
      authorize User
      scope = policy_scope(User)
        .left_joins(family: :subscription)
        .includes(:oidc_identities, family: :subscription)

      scope = scope.where(role: params[:role]) if params[:role].present?
      scope = apply_trial_filter(scope) if params[:trial_status].present?

      users = scope.order(
        Arel.sql(
          "CASE " \
          "WHEN subscriptions.status = 'trialing' THEN 0 " \
          "WHEN subscriptions.id IS NULL THEN 1 " \
          "ELSE 2 END, " \
          "subscriptions.trial_ends_at ASC NULLS LAST, users.email ASC"
        )
      )

      family_ids = users.map(&:family_id).uniq
      @accounts_count_by_family = Account.where(family_id: family_ids).group(:family_id).count
      @entries_count_by_family = Entry.joins(:account).where(accounts: { family_id: family_ids }).group("accounts.family_id").count

      user_ids = users.map(&:id).uniq
      @last_login_by_user = Session.where(user_id: user_ids).group(:user_id).maximum(:created_at)
      @sessions_count_by_user = Session.where(user_id: user_ids).group(:user_id).count

      @families_with_users = users.group_by(&:family).sort_by do |family, _users|
        -(@entries_count_by_family[family.id] || 0)
      end

      @invitations_by_family = Invitation.pending
        .where(family_id: family_ids)
        .group_by(&:family_id)

      @families = Family.order(:name, :created_at)
      @unused_families = Family.left_joins(:users).where(users: { id: nil }).order(:name, :created_at)

      @trials_expiring_in_7_days = Subscription
        .where(status: :trialing)
        .where(trial_ends_at: Time.current..7.days.from_now)
        .count
    end

    def update
      authorize @user

      if demoting_last_super_admin?
        redirect_to admin_users_path, alert: t(".last_super_admin_error")
        return
      end

      if membership_change_requested?
        target_family = nil

        ActiveRecord::Base.transaction do
          target_family = target_family_for_update

          if target_family.nil?
            raise ActiveRecord::Rollback
          end

          @user.transfer_to_family!(target_family, role: user_params[:role])
        end

        if target_family.nil?
          redirect_to admin_users_path, alert: t(".family_required")
          return
        end

        Rails.logger.info(
          "[Admin::Users] Family changed - " \
          "by_user_id=#{Current.user.id} " \
          "target_user_id=#{@user.id} " \
          "new_family_id=#{@user.family_id} " \
          "new_role=#{@user.role}"
        )
      elsif @user.update(role: user_params[:role])
        Rails.logger.info(
          "[Admin::Users] Role changed - " \
          "by_user_id=#{Current.user.id} " \
          "target_user_id=#{@user.id} " \
          "new_role=#{@user.role}"
        )
      else
        redirect_to admin_users_path, alert: @user.errors.full_messages.to_sentence.presence || t(".failure")
        return
      end

      redirect_to admin_users_path, notice: t(".success")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_users_path, alert: e.record.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_users_path, alert: t(".failure")
    end

    def destroy
      authorize @user

      if @user.purge
        redirect_to admin_users_path, notice: t(".destroy_success")
      else
        redirect_to admin_users_path, alert: t(".destroy_failure")
      end
    end

    private

      helper_method :family_label_for

      def set_user
        @user = User.find(params[:id])
      end

      def user_params
        params.require(:user).permit(:role, :family_id, :new_family_name, :new_family_moniker)
      end

      def membership_change_requested?
        new_family_name = user_params[:new_family_name].to_s.strip
        new_family_name.present? || (user_params[:family_id].present? && user_params[:family_id] != "new" && user_params[:family_id] != @user.family_id)
      end

      def target_family_for_update
        new_family_name = user_params[:new_family_name].to_s.strip

        if new_family_name.present?
          Family.create!(
            name: new_family_name,
            moniker: user_params[:new_family_moniker].presence || "Family"
          )
        elsif user_params[:family_id].present? && user_params[:family_id] != "new"
          Family.find(user_params[:family_id])
        end
      end

      def family_label_for(family)
        return "" if family.nil?

        family.name.presence || "#{family.moniker_label} (#{family.id.to_s.first(8)})"
      end

      def demoting_last_super_admin?
        user_params[:role].present? &&
          @user.super_admin? &&
          user_params[:role] != "super_admin" &&
          User.where(role: :super_admin).where.not(id: @user.id).none?
      end

      def apply_trial_filter(scope)
        case params[:trial_status]
        when "expiring_soon"
          scope.where(subscriptions: { status: :trialing })
            .where(subscriptions: { trial_ends_at: Time.current..7.days.from_now })
        when "trialing"
          scope.where(subscriptions: { status: :trialing })
        else
          scope
        end
      end
  end
end
