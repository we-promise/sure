# frozen_string_literal: true

module Admin
  class UsersController < Admin::BaseController
    before_action :set_user, only: %i[update deletion destroy]

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
      @last_login_by_user = User.where(id: user_ids).pluck(:id, :last_login_at).to_h
      @sessions_count_by_user = User.where(id: user_ids).pluck(:id, :sessions_count).to_h

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
      @sso_identity_blocks = SsoIdentityBlock.order(created_at: :desc)

      # Used by the view to hide the "remove" action for the sole remaining
      # active super admin, computed once here instead of per-row.
      @active_super_admin_count = User.where(role: :super_admin, active: true).count
    end

    def update
      authorize @user

      if demoting_last_super_admin?
        redirect_to admin_users_path, alert: t(".last_super_admin_error")
        return
      end

      if membership_change_requested? && password_change_requested?
        redirect_to admin_users_path, alert: t(".password_and_family_conflict")
        return
      end

      if password_change_requested?
        errors = validate_password_criteria(user_params[:password])
        if errors.any?
          redirect_to admin_users_path, alert: errors.join(" ")
          return
        end
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

        redirect_to admin_users_path, notice: t(".success_family")
      elsif @user.update(user_update_attributes)
        changes = []
        changes << :role if @user.saved_change_to_role?
        changes << :password if @user.saved_change_to_password_digest?

        success_key = case changes
        when [ :role, :password ] then ".success_role_and_password"
        when [ :password ]        then ".success_password"
        else                           ".success_role"
        end

        Rails.logger.info(
          "[Admin::Users] User details changed (#{changes.join(', ')}) - " \
          "by_user_id=#{Current.user.id} " \
          "target_user_id=#{@user.id} " \
          "new_role=#{@user.role}"
        )

        redirect_to admin_users_path, notice: t(success_key)
      else
        redirect_to admin_users_path, alert: @user.errors.full_messages.to_sentence.presence || t(".failure")
      end
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_users_path, alert: e.record.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_users_path, alert: t(".failure")
    end



    def deletion
      # Same self-removal short-circuit as #destroy. UserPolicy#destroy? already
      # denies it, but Pundit::NotAuthorizedError is not rescued anywhere in this
      # app, so opening the confirmation modal for yourself (the index view hides
      # the button, but the URL is guessable) would 500 instead of redirecting.
      if @user.id == Current.user.id
        redirect_to admin_users_path, alert: t("admin.users.destroy.cannot_remove_self")
        return
      end

      authorize @user, :destroy?
      render layout: false
    end

    def destroy
      # Self-removal is also denied by UserPolicy#destroy?, but checking it here
      # first turns it into a friendly redirect instead of an unhandled
      # Pundit::NotAuthorizedError (there is no rescue_from for it in this app).
      if @user.id == Current.user.id
        redirect_to admin_users_path, alert: t(".cannot_remove_self")
        return
      end

      authorize @user

      unless ActiveSupport::SecurityUtils.secure_compare(params[:confirmation_email].to_s, @user.email)
        redirect_to admin_users_path, alert: t(".confirmation_mismatch")
        return
      end

      removed = @user.transaction do
        next false unless @user.permanently_remove!

        SsoAuditLog.log_user_removed!(user: @user, actor: Current.user, request: request)
        true
      end

      if removed
        redirect_to admin_users_path, notice: t(".success")
      else
        redirect_to admin_users_path, alert: @user.errors.full_messages.to_sentence.presence || t(".failure")
      end
    end

    private

      helper_method :family_label_for

      def set_user
        @user = User.find(params[:id])
      end

      def user_params
        params.require(:user).permit(:role, :family_id, :new_family_name, :new_family_moniker, :password)
      end

      def user_update_attributes
        attrs = {}
        attrs[:role] = user_params[:role] if user_params[:role].present?
        if user_params[:password].present? && @user.has_local_password?
          attrs[:password] = user_params[:password]
        end
        attrs
      end

      def password_change_requested?
        user_params[:password].present? && @user.has_local_password?
      end

      def validate_password_criteria(password)
        errors = []
        errors << t(".password_too_short") if password.length < 8
        errors << t(".password_missing_case") unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
        errors << t(".password_missing_number") unless password.match?(/\d/)
        errors << t(".password_missing_special") unless password.match?(/[!@#$%^&*(),.?":{}|<>]/)
        errors
      end

      def membership_change_requested?
        return true if user_params[:new_family_name].to_s.strip.present?
        return true if user_params[:family_id] == "new"

        user_params[:family_id].present? && user_params[:family_id] != @user.family_id.to_s
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
