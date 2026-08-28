class Session < ApplicationRecord
  include Encryptable

  # Encrypt user_agent if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :user_agent
  end

  # Sessions have no explicit expiry column; a session is considered expired
  # once it hasn't been touched (see Authentication#find_session_by_cookie)
  # for this long. Without this, the signed session cookie is `.permanent`
  # (20 years) and a stolen cookie would grant indefinite access.
  INACTIVITY_TIMEOUT = 30.days

  # Only keys actually rendered by DS::Tabs (session_key:) may be persisted.
  # Without this, PUT /current_session accepts any tab_key/tab_value pair
  # from the client and writes it straight into this record's jsonb column.
  ALLOWED_TAB_KEYS = %w[account_sidebar_tab].freeze

  belongs_to :user, counter_cache: :sessions_count
  belongs_to :active_impersonator_session,
    -> { where(status: :in_progress) },
    class_name: "ImpersonationSession",
    optional: true

  before_create :capture_session_info

  after_create :update_user_last_login

  class << self
    def clean
      count = 0
      where("updated_at < ?", INACTIVITY_TIMEOUT.ago).find_each do |session|
        # Recheck under a row lock: a request may have touched this session
        # (see Authentication#find_session_by_cookie) between the query above
        # and this iteration, in which case it is no longer inactive.
        session.with_lock do
          next unless session.updated_at < INACTIVITY_TIMEOUT.ago
          session.destroy
          count += 1
        end
      end
      count
    end

    # Shared cookie -> Session resolver used by every path that authenticates
    # via the signed session_token cookie (Authentication concern, Doorkeeper
    # authenticators, SuperAdminConstraint), so inactivity expiry can't be
    # bypassed by adding a new entry point that forgets to check `expired?`.
    def find_active_by_cookie(cookie_value)
      return nil if cookie_value.blank?

      session_record = includes(:user).find_by(id: cookie_value)
      return nil unless session_record

      if session_record.user&.active? && !session_record.expired?
        session_record
      else
        session_record.destroy!
        nil
      end
    end
  end

  def prev_transaction_page_params
    super || {}
  end


  def get_preferred_tab(tab_key)
    data.dig("tab_preferences", tab_key)
  end

  def set_preferred_tab(tab_key, tab_value)
    return unless ALLOWED_TAB_KEYS.include?(tab_key)

    data["tab_preferences"] ||= {}
    data["tab_preferences"][tab_key] = tab_value
    save!
  end

  def expired?
    updated_at < INACTIVITY_TIMEOUT.ago
  end

  private

    def capture_session_info
      self.user_agent = Current.user_agent
      raw_ip = Current.ip_address
      self.ip_address = raw_ip
      self.ip_address_digest = Digest::SHA256.hexdigest(raw_ip.to_s) if raw_ip.present?
    end

    def update_user_last_login
      user.update_columns(last_login_at: created_at)
    end
end
