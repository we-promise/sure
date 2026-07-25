# Routing constraint for mounting engines that bypass ApplicationController
# entirely (e.g. Sidekiq::Web). Resolves the signed session cookie the same
# way Authentication#find_session_by_cookie does and requires the session's
# user to be a super admin.
#
# The session's user is always the TRUE user: impersonation is resolved at the
# Current level, so an impersonated member can never satisfy this, and a
# super admin impersonating someone still is one. Sessions are only created
# after MFA verification, so this does not bypass MFA either.
#
# Fails closed: any error (garbage cookie, unreachable DB) means the route
# does not exist for the request (404).
class SuperAdminConstraint
  def matches?(request)
    cookie_value = request.cookie_jar.signed[:session_token]
    return false if cookie_value.blank?

    Session.find_by(id: cookie_value)&.user&.super_admin? || false
  rescue => e
    Rails.logger.warn("SuperAdminConstraint rejected request: #{e.class}: #{e.message}")
    false
  end
end
