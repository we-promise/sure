class User < ApplicationRecord
  include Encryptable

  # Allow nil password for SSO-only users (JIT provisioning).
  # Custom validation ensures password is present for non-SSO registration.
  has_secure_password validations: false

  # Encrypt sensitive fields if ActiveRecord encryption is configured
  if encryption_ready?
    # MFA secrets
    encrypts :otp_secret, deterministic: true
    # Note: otp_backup_codes is a PostgreSQL array column which doesn't support
    # AR encryption. To encrypt it, a migration would be needed to change the
    # column type from array to text/jsonb.

    # PII - emails (deterministic for lookups, downcase for case-insensitive)
    encrypts :email, deterministic: true, downcase: true
    encrypts :unconfirmed_email, deterministic: true, downcase: true

    # PII - names (non-deterministic for maximum security)
    encrypts :first_name
    encrypts :last_name
  end

  belongs_to :family
  belongs_to :last_viewed_chat, class_name: "Chat", optional: true
  has_many :sessions, dependent: :destroy
  has_many :chats, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :mobile_devices, dependent: :destroy
  has_many :invitations, foreign_key: :inviter_id, dependent: :destroy
  has_many :impersonator_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonator_id, dependent: :destroy
  has_many :impersonated_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonated_id, dependent: :destroy
  has_many :oidc_identities, dependent: :destroy
  has_many :sso_audit_logs, dependent: :nullify
  accepts_nested_attributes_for :family, update_only: true

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validate :ensure_valid_profile_image
  validates :default_period, inclusion: { in: Period::PERIODS.keys }
  validates :default_account_order, inclusion: { in: AccountOrder::ORDERS.keys }
  validates :locale, inclusion: { in: I18n.available_locales.map(&:to_s) }, allow_nil: true

  # Password is required on create unless the user is being created via SSO JIT.
  # SSO JIT users have password_digest = nil and authenticate via OIDC only.
  validates :password, presence: true, on: :create, unless: :skip_password_validation?
  validates :password, length: { minimum: 8 }, allow_nil: true
  normalizes :email, with: ->(email) { email.strip.downcase }
  normalizes :unconfirmed_email, with: ->(email) { email&.strip&.downcase }

  normalizes :first_name, :last_name, with: ->(value) { value.strip.presence }

  enum :role, { guest: "guest", member: "member", admin: "admin", super_admin: "super_admin" }, validate: true
  enum :ui_layout, { dashboard: "dashboard", intro: "intro" }, validate: true, prefix: true

  before_validation :apply_ui_layout_defaults
  before_validation :apply_role_based_ui_defaults

  # Returns the appropriate role for a new user creating a family.
  # The very first user of an instance becomes super_admin; subsequent users
  # get the specified fallback role (typically :admin for family creators).
  def self.role_for_new_family_creator(fallback_role: :admin)
    User.exists? ? fallback_role : :super_admin
  end

  has_one_attached :profile_image, dependent: :purge_later do |attachable|
    attachable.variant :thumbnail, resize_to_fill: [ 300, 300 ], convert: :webp, saver: { quality: 80 }
    attachable.variant :small, resize_to_fill: [ 72, 72 ], convert: :webp, saver: { quality: 80 }, preprocessed: true
  end

  validate :profile_image_size

  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  generates_token_for :email_confirmation, expires_in: 1.day do
    unconfirmed_email
  end

  def pending_email_change?
    unconfirmed_email.present?
  end

  def initiate_email_change(new_email)
    return false if new_email == email

    if Rails.application.config.app_mode.self_hosted? && !Setting.require_email_confirmation
      update(email: new_email)
    else
      if update(unconfirmed_email: new_email)
        EmailConfirmationMailer.with(user: self).confirmation_email.deliver_later
        true
      else
        false
      end
    end
  end

  def resend_confirmation_email
    if pending_email_change?
      EmailConfirmationMailer.with(user: self).confirmation_email.deliver_later
      true
    else
      false
    end
  end

  def request_impersonation_for(user_id)
    impersonated = User.find(user_id)
    impersonator_support_sessions.create!(impersonated: impersonated)
  end

  def admin?
    super_admin? || role == "admin"
  end

  def display_name
    [ first_name, last_name ].compact.join(" ").presence || email
  end

  def initial
    (display_name&.first || email.first).upcase
  end

  def initials
    if first_name.present? && last_name.present?
      "#{first_name.first}#{last_name.first}".upcase
    else
      initial
    end
  end

  def show_ai_sidebar?
    show_ai_sidebar
  end

  def ai_available?
    !Rails.application.config.app_mode.self_hosted? || ENV["OPENAI_ACCESS_TOKEN"].present? || Setting.openai_access_token.present?
  end

  def ai_enabled?
    ai_enabled && ai_available?
  end

  def self.default_ui_layout
    layout = Rails.application.config.x.ui&.default_layout || "dashboard"
    layout.in?(%w[intro dashboard]) ? layout : "dashboard"
  end

  # SSO-only users have OIDC identities but no local password.
  # They cannot use password reset or local login.
  def sso_only?
    password_digest.nil? && oidc_identities.exists?
  end

  # Check if user has a local password set (can authenticate locally)
  def has_local_password?
    password_digest.present?
  end

  # Attribute to skip password validation during SSO JIT provisioning
  attr_accessor :skip_password_validation

  # Deactivation
  validate :can_deactivate, if: -> { active_changed? && !active }
  after_update_commit :purge_later, if: -> { saved_change_to_active?(from: true, to: false) }

  def deactivate
    update active: false, email: deactivated_email
  end

  def can_deactivate
    if admin? && family.users.count > 1
      errors.add(:base, :cannot_deactivate_admin_with_other_users)
    end
  end

  def purge_later
    UserPurgeJob.perform_later(self)
  end

  def purge
    if last_user_in_family?
      family.destroy
    else
      destroy
    end
  end

  # MFA
  def setup_mfa!
    update!(
      otp_secret: ROTP::Base32.random(32),
      otp_required: false,
      otp_backup_codes: []
    )
  end

  def enable_mfa!
    update!(
      otp_required: true,
      otp_backup_codes: generate_backup_codes
    )
  end

  def disable_mfa!
    update!(
      otp_secret: nil,
      otp_required: false,
      otp_backup_codes: []
    )
  end

  def verify_otp?(code)
    return false if otp_secret.blank?
    return true if verify_backup_code?(code)
    totp.verify(code, drift_behind: 15)
  end

  def provisioning_uri
    return nil unless otp_secret.present?
    totp.provisioning_uri(email)
  end

  def onboarded?
    onboarded_at.present?
  end

  def needs_onboarding?
    !onboarded?
  end

  def account_order
    AccountOrder.find(default_account_order) || AccountOrder.default
  end

  # Dashboard preferences management
  def dashboard_section_collapsed?(section_key)
    preferences&.dig("collapsed_sections", section_key) == true
  end

  def dashboard_section_order
    preferences&.[]("section_order") || default_dashboard_section_order
  end

  def update_dashboard_preferences(prefs)
    # Use pessimistic locking to ensure atomic read-modify-write
    # This prevents race conditions when multiple sections are collapsed quickly
    transaction do
      lock! # Acquire row-level lock (SELECT FOR UPDATE)

      updated_prefs = (preferences || {}).deep_dup
      prefs.each do |key, value|
        if value.is_a?(Hash)
          updated_prefs[key] ||= {}
          updated_prefs[key] = updated_prefs[key].merge(value)
        else
          updated_prefs[key] = value
        end
      end

      update!(preferences: updated_prefs)
    end
  end

  # Reports preferences management
  def reports_section_collapsed?(section_key)
    preferences&.dig("reports_collapsed_sections", section_key) == true
  end

  def reports_section_order
    preferences&.[]("reports_section_order") || default_reports_section_order
  end

  def update_reports_preferences(prefs)
    # Use pessimistic locking to ensure atomic read-modify-write
    transaction do
      lock!

      updated_prefs = (preferences || {}).deep_dup
      prefs.each do |key, value|
        if value.is_a?(Hash)
          updated_prefs[key] ||= {}
          updated_prefs[key] = updated_prefs[key].merge(value)
        else
          updated_prefs[key] = value
        end
      end

      update!(preferences: updated_prefs)
    end
  end

  # Transactions preferences management
  def transactions_section_collapsed?(section_key)
    preferences&.dig("transactions_collapsed_sections", section_key) == true
  end

  def update_transactions_preferences(prefs)
    transaction do
      lock!

      updated_prefs = (preferences || {}).deep_dup
      prefs.each do |key, value|
        if value.is_a?(Hash)
          updated_prefs["transactions_#{key}"] ||= {}
          updated_prefs["transactions_#{key}"] = updated_prefs["transactions_#{key}"].merge(value)
        else
          updated_prefs["transactions_#{key}"] = value
        end
      end

      update!(preferences: updated_prefs)
    end
  end

  private
    def apply_ui_layout_defaults
      self.ui_layout = (ui_layout.presence || self.class.default_ui_layout)
    end

    def apply_role_based_ui_defaults
      if ui_layout_intro?
        if guest?
          self.show_sidebar = false
          self.show_ai_sidebar = false
          self.ai_enabled = true
        else
          self.ui_layout = "dashboard"
        end
      elsif guest?
        self.ui_layout = "intro"
        self.show_sidebar = false
        self.show_ai_sidebar = false
        self.ai_enabled = true
      end

      if leaving_guest_role?
        self.show_sidebar = true unless show_sidebar
        self.show_ai_sidebar = true unless show_ai_sidebar
      end
    end

    def leaving_guest_role?
      return false unless will_save_change_to_role?

      previous_role, new_role = role_change_to_be_saved
      previous_role == "guest" && new_role != "guest"
    end

    def skip_password_validation?
      skip_password_validation == true
    end

    def default_dashboard_section_order
      %w[cashflow_sankey outflows_donut net_worth_chart balance_sheet]
    end

    def default_reports_section_order
      %w[trends_insights transactions_breakdown]
    end
    def ensure_valid_profile_image
      return unless profile_image.attached?

      unless profile_image.content_type.in?(%w[image/jpeg image/png])
        errors.add(:profile_image, "must be a JPEG or PNG")
        profile_image.purge
      end
    end

    def last_user_in_family?
      family.users.count == 1
    end

    def deactivated_email
      email.gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")
    end

    def profile_image_size
      if profile_image.attached? && profile_image.byte_size > 10.megabytes
        errors.add(:profile_image, :invalid_file_size, max_megabytes: 10)
      end
    end

    def totp
      ROTP::TOTP.new(otp_secret, issuer: "Sure Finances")
    end

    def verify_backup_code?(code)
      return false if otp_backup_codes.blank?

      # Find and remove the used backup code
      if (index = otp_backup_codes.index(code))
        remaining_codes = otp_backup_codes.dup
        remaining_codes.delete_at(index)
        update!(otp_backup_codes: remaining_codes)
        true
      else
        false
      end
    end

    def generate_backup_codes
      8.times.map { SecureRandom.hex(4) }
    end
end
