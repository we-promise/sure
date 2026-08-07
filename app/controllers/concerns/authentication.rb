module Authentication
  extend ActiveSupport::Concern

  REMOTE_HEADER_SSO_PROVIDER = "remote_user_header"

  # How far back to look for a session belonging to the same header-authenticated
  # client, and how many candidates to decrypt while matching on user agent.
  REMOTE_HEADER_SESSION_REUSE_WINDOW = 12.hours
  REMOTE_HEADER_SESSION_REUSE_CANDIDATES = 10

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
      cookie_session = find_session_by_cookie

      if cookie_session && cookie_session_disagrees_with_resolved_header_user?(cookie_session)
        cookie_session.destroy
        cookies.delete(:session_token)
        cookie_session = nil
      end

      if cookie_session
        Current.session = cookie_session
      elsif session_record = create_session_by_remote_header
        Current.session = session_record
      else
        if self_hosted_first_login?
          redirect_to new_registration_url
        else
          redirect_to new_session_url
        end
      end
    end

    def cookie_session_disagrees_with_resolved_header_user?(session)
      user, = resolved_remote_header_user
      user.present? && session.user != user
    end

    def create_session_by_remote_header
      user, created = resolved_remote_header_user
      return unless user

      if created
        SsoAuditLog.log_jit_account_created!(
          user: user,
          provider: REMOTE_HEADER_SSO_PROVIDER,
          request: request
        )
      elsif existing_session = reusable_remote_header_session_for(user)
        # The proxy stamps the header on every request it forwards, so any
        # cookieless client (curl, health checks, crawlers) would otherwise mint
        # a Session and an SsoAuditLog row per request. Hand the same client its
        # existing session back instead, and don't re-log a login it never made.
        cookies.signed.permanent[:session_token] = { value: existing_session.id, httponly: true }
        existing_session.touch
        return existing_session
      end

      SsoAuditLog.log_login!(
        user: user,
        provider: REMOTE_HEADER_SSO_PROVIDER,
        request: request
      )
      create_session_for(user)
    end

    # Returns [ user, created ] for the header assertion, or [ nil, false ] when
    # there isn't one or it can't be honored. Memoized because the cookie-vs-header
    # check and the session build both need it, and resolving twice would mean a
    # second lookup — or a second JIT creation attempt — on the same request.
    def resolved_remote_header_user
      return @resolved_remote_header_user if defined?(@resolved_remote_header_user)

      user_email = trusted_remote_user_email
      @resolved_remote_header_user = user_email ? find_or_create_remote_header_user(user_email) : [ nil, false ]
    end

    # Most recent session that looks like the same client coming back. Keyed on
    # the indexed ip_address_digest; user_agent is compared in Ruby because it's
    # encrypted non-deterministically when ActiveRecord encryption is configured
    # and so can't appear in a WHERE clause. This must use Current.ip_address:
    # Session stores request.ip, not the trusted proxy peer in REMOTE_ADDR.
    def reusable_remote_header_session_for(user)
      digest = Session.ip_address_digest_for(Current.ip_address)
      return nil if digest.blank?

      user.sessions
          .where(ip_address_digest: digest, active_impersonator_session_id: nil)
          .where(created_at: REMOTE_HEADER_SESSION_REUSE_WINDOW.ago..)
          .order(created_at: :desc)
          .limit(REMOTE_HEADER_SESSION_REUSE_CANDIDATES)
          .find { |candidate| candidate.user_agent == Current.user_agent }
    end

    # Returns the email asserted by the upstream proxy, but only when the
    # request passes all configured trust gates: self-hosted mode, header
    # set, source IP in the trusted-proxies allowlist, shared-secret match
    # (if configured), and email shape is valid.
    #
    # Memoized independently from user resolution so callers that only need the
    # trusted assertion don't perform a database lookup or JIT creation.
    def trusted_remote_user_email
      return @trusted_remote_user_email if defined?(@trusted_remote_user_email)

      @trusted_remote_user_email = computed_trusted_remote_user_email
    end

    def computed_trusted_remote_user_email
      return nil unless Rails.application.config.app_mode.self_hosted?

      header_name = Rails.application.config.remote_user_header_email
      return nil if header_name.blank?

      # Check for the header before the gates so an ordinary unauthenticated
      # request doesn't log a rejection for a header it never sent.
      raw_email = request.headers[header_name]
      return nil if raw_email.blank?

      return nil unless remote_user_proxy_trusted?
      return nil unless remote_user_secret_valid?

      email = raw_email.strip.downcase
      return nil if email.blank?

      unless URI::MailTo::EMAIL_REGEXP.match?(email)
        return reject_remote_user_header("malformed email in #{header_name}", value: raw_email)
      end

      email
    end

    def remote_user_proxy_trusted?
      trusted = Rails.application.config.remote_user_trusted_proxies
      peer = request.env["REMOTE_ADDR"]
      peer_ip = IPAddr.new(peer)
      # IPAddr#include? never crosses address families, so an IPv4-mapped IPv6
      # peer (::ffff:127.0.0.1 — routine for a dual-stack nginx or Docker
      # front-end) matches neither an IPv4 nor an IPv6 range. Compare the
      # native IPv4 form instead.
      peer_ip = peer_ip.native if peer_ip.ipv4_mapped?

      return true if trusted.any? { |range| range.include?(peer_ip) }

      reject_remote_user_header("peer not in REMOTE_USER_TRUSTED_PROXIES", peer: peer)
      false
    rescue IPAddr::Error => e
      reject_remote_user_header("unparseable REMOTE_ADDR (#{e.class})", peer: peer)
      false
    end

    def remote_user_secret_valid?
      expected = Rails.application.config.remote_user_shared_secret
      return true if expected.blank?

      header_name = Rails.application.config.remote_user_shared_secret_header
      provided = request.headers[header_name].to_s
      return true if ActiveSupport::SecurityUtils.secure_compare(expected, provided)

      reject_remote_user_header(
        provided.blank? ? "#{header_name} missing" : "#{header_name} does not match REMOTE_USER_SHARED_SECRET"
      )
      false
    end

    # Returns [ user, created ]. A nil user means the request fails closed to
    # unauthenticated rather than raising out of the before_action.
    def find_or_create_remote_header_user(user_email)
      if user = User.find_by(email: user_email)
        unless user.active?
          reject_remote_user_header("account is deactivated", email: user_email)
          return [ nil, false ]
        end

        return [ user, false ]
      end

      create_remote_header_user(user_email)
    end

    def create_remote_header_user(user_email)
      unless User.exists?
        reject_remote_user_header("first account must be created through registration", email: user_email)
        return [ nil, false ]
      end

      # Mirrors OidcAccountsController#create_user: a pending invitation always
      # wins, otherwise the instance's JIT policy decides.
      invitation = Invitation.pending.find_by(email: user_email)
      return [ nil, false ] unless remote_header_jit_allowed?(user_email, invitation)

      # Leave password_digest nil so the user can't fall back to local
      # password login or password reset; the proxy is the only path in.
      user = User.new
      user.email = user_email
      user.skip_password_validation = true

      if invitation
        user.family_id = invitation.family_id
        user.role = invitation.role
      else
        user.family = Family.new
        # The first-account guard above keeps the normal registration bootstrap,
        # so this always resolves to the fallback :admin role.
        user.role = User.role_for_new_family_creator(fallback_role: :admin)
      end

      begin
        ActiveRecord::Base.transaction do
          user.save!
          if invitation
            invitation.update!(accepted_at: Time.current)
            # Matches Invitation#accept_for: without this the invitee lands in
            # the family but sees none of its accounts.
            user.family.auto_share_existing_accounts_with(user)
          end
        end
        [ user, true ]
      rescue ActiveRecord::RecordNotUnique
        # Concurrent first requests for the same header email; the other one won.
        existing = User.find_by(email: user_email)
        existing&.active? ? [ existing, false ] : [ nil, false ]
      rescue ActiveRecord::RecordInvalid => e
        # save! runs inside a before_action, so anything unrescued here 500s
        # every request until the proxy config changes.
        reject_remote_user_header("could not create user (#{e.record&.errors&.full_messages&.to_sentence})", email: user_email)
        [ nil, false ]
      end
    end

    def remote_header_jit_allowed?(user_email, invitation)
      return true if invitation.present?

      unless Rails.application.config.remote_user_allow_jit
        reject_remote_user_header("REMOTE_USER_ALLOW_JIT is false and no account exists", email: user_email)
        return false
      end

      if AuthConfig.jit_link_only?
        reject_remote_user_header("AUTH_JIT_MODE is link_only and no account exists", email: user_email)
        return false
      end

      unless AuthConfig.allowed_oidc_domain?(user_email)
        reject_remote_user_header("domain not in ALLOWED_OIDC_DOMAINS", email: user_email)
        return false
      end

      true
    end

    # Rejections are otherwise completely silent, which makes a misconfigured
    # proxy indistinguishable from a broken login. Deliberately Rails.logger and
    # not DebugLogEntry: this runs per request and any untrusted peer can
    # trigger it, so it must not write to the database.
    def reject_remote_user_header(reason, **details)
      annotated = details.compact.map { |key, value| " #{key}=#{value.to_s.truncate(80).inspect}" }.join
      Rails.logger.warn("[remote_user_header] ignoring header: #{reason}#{annotated}")
      nil
    end

    # Proxy sign-out URL, when header auth is actually in play. Destroying the
    # local session alone is a no-op here: the header is still on the next
    # request, so the user is immediately signed back in.
    def remote_user_header_logout_url
      return nil unless Rails.application.config.app_mode.self_hosted?
      return nil if Rails.application.config.remote_user_header_email.blank?
      return nil if trusted_remote_user_email.blank?

      Rails.application.config.remote_user_logout_url
    end

    def find_session_by_cookie
      cookie_value = cookies.signed[:session_token]

      if cookie_value.present?
        Session.find_by(id: cookie_value)
      else
        nil
      end
    end

    def create_session_for(user)
      session = user.sessions.create!
      cookies.signed.permanent[:session_token] = { value: session.id, httponly: true }
      session
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
