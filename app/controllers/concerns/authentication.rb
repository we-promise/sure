module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :set_request_details
    before_action :authenticate_user!
    before_action :set_sentry_user
  end

  class_methods do
    def skip_authentication(**options)
      skip_before_action :authenticate_user!, **options
      skip_before_action :set_sentry_user, **options
    end
  end

  private
    def authenticate_user!
      if session_record = find_session_by_cookie
        Current.session = session_record
        end_impersonation_if_target_inactive!
        end_orphaned_session!
      else
        if self_hosted_first_login?
          redirect_to new_registration_url
        else
          redirect_to new_session_url
        end
      end
    end

    def find_session_by_cookie
      session_record = Session.find_active_by_cookie(cookies.signed[:session_token])
      return session_record if session_record

      cookies.delete(:session_token)
      nil
    end

    def create_session_for(user)
      return false unless user&.persisted?

      user.with_active_lock! do
        session = user.sessions.create!
        cookies.signed.permanent[:session_token] = { value: session.id, httponly: true }
        session
      end
    rescue User::InactiveError
      false
    end

    # If a super admin is currently impersonating a user who gets deactivated
    # mid-session, end the impersonation (same mechanism as
    # ImpersonationSessionsController#leave) rather than logging the admin out
    # entirely — their own session is still valid.
    def end_impersonation_if_target_inactive!
      impersonation = Current.session&.active_impersonator_session
      return unless impersonation && !impersonation.impersonated.active?

      Rails.logger.warn(
        "[AUTH] Ending impersonation_session_id=#{impersonation.id}: " \
        "impersonated user_id=#{impersonation.impersonated_id} is deactivated"
      )
      Current.session.update!(active_impersonator_session: nil)
    end

    # A session can outlive its user/family when they are destroyed while this
    # request is in flight (e.g. the session touch in Session.find_active_by_cookie
    # waits on a row lock held by a family/user purge, which then commits). The
    # in-memory user is stale and its family is gone, so treat the session as
    # dead instead of letting downstream code call methods on a nil family.
    #
    # While impersonating, Current.user is the impersonated user but
    # Current.session is the super admin's own session. If only the impersonated
    # user's family vanished, end the impersonation (like
    # end_impersonation_if_target_inactive!) and keep the admin signed in.
    def end_orphaned_session!
      end_impersonation_if_target_orphaned!
      return if Current.user && Current.family

      session_record = Current.session
      Rails.logger.warn(
        "[AUTH] Ending orphaned session_id=#{session_record&.id}: " \
        "user_id=#{session_record&.user_id} family_id=#{Current.user&.family_id.inspect} no longer exists"
      )

      Session.where(id: session_record.id).delete_all if session_record
      cookies.delete(:session_token)
      Current.session = nil
      redirect_to new_session_url
    end

    def end_impersonation_if_target_orphaned!
      impersonated = Current.impersonated_user
      return unless impersonated && impersonated.family.nil?

      Rails.logger.warn(
        "[AUTH] Ending impersonation_session_id=#{Current.session.active_impersonator_session_id}: " \
        "impersonated user_id=#{impersonated.id} family_id=#{impersonated.family_id.inspect} no longer exists"
      )
      Current.session.update!(active_impersonator_session: nil)
    end

    def self_hosted_first_login?
      Rails.application.config.app_mode.self_hosted? && User.count.zero?
    end

    def set_request_details
      Current.user_agent = request.user_agent
      Current.ip_address = request.ip
    end

    def set_sentry_user
      return unless defined?(Sentry) && ENV["SENTRY_DSN"].present?

      if Current.user
        Sentry.set_user(
          id: Current.user.id,
          email: Current.user.email,
          username: Current.user.display_name,
          ip_address: Current.ip_address
        )
      end
    end
end
