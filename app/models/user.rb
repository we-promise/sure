class User < ApplicationRecord
  include Encryptable

  # Allow nil password for SSO-only users (JIT provisioning).
  # Custom validation ensures password is present for non-SSO registration.
  has_secure_password validations: false

  # Encrypt sensitive fields if ActiveRecord encryption is configured
  if encryption_ready?
    # MFA secrets
    encrypts :otp_secret, deterministic: true

    # PII - emails (deterministic for lookups, downcase for case-insensitive)
    encrypts :email, deterministic: true, downcase: true
    encrypts :unconfirmed_email, deterministic: true, downcase: true

    # PII - names (non-deterministic for maximum security)
    encrypts :first_name
    encrypts :last_name
  end

  belongs_to :family
  belongs_to :last_viewed_chat, class_name: "Chat", optional: true
  belongs_to :default_account, class_name: "Account", optional: true
  has_many :sessions, dependent: :destroy
  has_many :chats, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :push_subscriptions, dependent: :destroy
  has_many :webauthn_credentials, dependent: :destroy
  has_many :mobile_devices, dependent: :destroy
  has_many :invitations, foreign_key: :inviter_id, dependent: :destroy
  has_many :impersonator_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonator_id, dependent: :destroy
  has_many :impersonated_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonated_id, dependent: :destroy
  has_many :oidc_identities, dependent: :destroy
  has_many :sso_audit_logs, dependent: :nullify
  has_many :owned_accounts, class_name: "Account", foreign_key: :owner_id
  has_many :account_shares, dependent: :destroy
  has_many :shared_accounts, through: :account_shares, source: :account
  has_many :budget_shares_given, class_name: "BudgetShare", foreign_key: :owner_id, inverse_of: :owner, dependent: :destroy
  has_many :budget_shares_received, class_name: "BudgetShare", foreign_key: :viewer_id, inverse_of: :viewer, dependent: :destroy
  accepts_nested_attributes_for :family, update_only: true

  MFA_BACKUP_CODE_COUNT = 8

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
  normalizes :locale, with: ->(locale) { locale.presence }

  normalizes :first_name, :last_name, with: ->(value) { value.strip.presence }

  enum :role, { guest: "guest", member: "member", admin: "admin", super_admin: "super_admin" }, validate: true

  # SQL counterpart to #preview_features_enabled?, for callers that filter
  # users (or their families) in one query instead of loading and iterating.
  # The `@>` containment operator uses index_users_on_preferences (GIN) and
  # matches only a JSON boolean true, so it agrees with that predicate's
  # strict `== true` — a stray "yes" enables neither.
  scope :with_preview_features, -> {
    where("preferences @> ?", { preview_features_enabled: true }.to_json)
  }

  attribute :ui_layout, :string
  enum :ui_layout, { dashboard: "dashboard", intro: "intro" }, validate: true, prefix: true

  before_validation :apply_ui_layout_defaults
  before_validation :apply_role_based_ui_defaults

  # Returns the appropriate role for a new user creating a family.
  # The very first user of an instance becomes super_admin; subsequent users
  # get the specified admin-capable fallback role.
  # Keep this one-key advisory lock stable across deploys so old and new app
  # processes serialize first-user role selection on the same database lock.
  FIRST_USER_ROLE_LOCK_KEY = 8_391_247

  def self.lock_first_user_role!
    connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", FIRST_USER_ROLE_LOCK_KEY ]))
  end

  def self.role_for_new_family_creator(fallback_role: :admin)
    fallback_role = fallback_role.to_s.in?(%w[admin super_admin]) ? fallback_role : :admin

    User.exists? ? fallback_role : :super_admin
  end

  class << self
    def human_attribute_name(attribute, options = {})
      locale = options[:locale] || I18n.locale
      moniker = I18n.with_locale(locale) do
        Current.family&.moniker_label || I18n.t("shared.family_moniker.singular", default: "Family")
      end

      options = {
        moniker: moniker
      }.merge(options)

      super(attribute, options)
    end
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

  def accessible_accounts
    family.accounts.accessible_by(self)
  end

  def finance_accounts
    family.accounts.included_in_finances_for(self)
  end

  # Other family members who have granted this user access to their personal
  # budget (see BudgetShare). Used to build the budget owner switcher.
  def budget_owners_shared_with_me
    User.where(id: budget_shares_received.select(:owner_id))
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
    return true unless Rails.application.config.app_mode.self_hosted?

    effective_type = ENV["ASSISTANT_TYPE"].presence || family&.assistant_type.presence || "builtin"

    case effective_type
    when "external"
      Assistant::External.available_for?(self)
    else
      openai_configured? || anthropic_configured?
    end
  end

  def openai_configured?
    Provider::Openai.configured?
  end

  def anthropic_configured?
    Provider::Anthropic.configured?
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
    password_digest.nil? && oidc_identities.any?
  end

  # Check if user has a local password set (can authenticate locally)
  def has_local_password?
    password_digest.present?
  end

  # Attribute to skip password validation during SSO JIT provisioning
  attr_accessor :skip_password_validation

  # Deactivation
  validate :can_deactivate, if: -> { active_changed? && !active }

  # Super Admin Invariant
  validate :ensure_not_last_super_admin, if: :losing_super_admin_privileges?
  before_destroy :ensure_not_last_super_admin_on_destroy

  after_update_commit :purge_later, if: -> { saved_change_to_active?(from: true, to: false) }

  def deactivate
    return true unless active?

    transaction do
      update(active: false, email: deactivated_email)
    end || false
  end

  private

    def losing_super_admin_privileges?
      (role_changed? && role_was == "super_admin" && role != "super_admin") ||
        (active_changed? && active_was == true && !active && role == "super_admin")
    end

    def ensure_not_last_super_admin
      return unless check_last_super_admin_invariant_failed?

      attribute = role_changed? ? :role : :base
      errors.add(attribute, :cannot_remove_last_super_admin, message: I18n.t("admin.users.update.last_super_admin_error"))
    end

    def ensure_not_last_super_admin_on_destroy
      return unless role == "super_admin" && active?

      if check_last_super_admin_invariant_failed?
        errors.add(:base, :cannot_remove_last_super_admin, message: I18n.t("admin.users.update.last_super_admin_error"))
        throw(:abort)
      end
    end

    def check_last_super_admin_invariant_failed?
      # Lock all active super admins in a consistent order to prevent deadlocks
      locked_ids = User.where(role: :super_admin, active: true).order(:id).lock.pluck(:id)
      locked_ids.size <= 1 && locked_ids.include?(id)
    end

  public

  # Permanent removal of another user, initiated by a super admin from the
  # instance users page. Reuses the sanctioned deactivate -> UserPurgeJob path
  # (which reassigns owned accounts, or destroys the family when this is its
  # last member) for the heavy data cleanup, but additionally revokes every
  # live authentication vector *synchronously* so there is no window in which
  # the removed user can keep acting or re-authenticate before the async purge
  # runs. Returns false (with errors populated) when the user cannot be
  # deactivated, e.g. an admin who still has co-members in their family.
  def permanently_remove!
    was_active = active?
    removed = transaction do
      identity_label = email
      raise ActiveRecord::Rollback unless deactivate

      SsoIdentityBlock.block_all!(oidc_identities, identity_label: identity_label)
      revoke_all_credentials!
      true
    end || false

    purge_later if removed && !was_active
    removed
  end

  # Destroys every credential/session that can authenticate as this user.
  # Web sessions and the SSO identity re-auth path (OidcIdentity lookup by
  # provider+uid) are not gated on #active?, so they must be torn down here for
  # revocation to be immediate; the async purge would otherwise leave a window.
  def revoke_all_credentials!
    Doorkeeper::AccessToken
      .where(resource_owner_id: id, revoked_at: nil)
      .update_all(revoked_at: Time.current)
    sessions.destroy_all
    api_keys.destroy_all
    mobile_devices.destroy_all
    webauthn_credentials.destroy_all
    oidc_identities.destroy_all
  end

  def can_deactivate
    if admin? && family.users.count > 1
      errors.add(:base, :cannot_deactivate_admin_with_other_users)
    end
  end

  def purge_later
    UserPurgeJob.perform_later(self)
  end

  def transfer_to_family!(new_family, role: self.role)
    transaction do
      lock!

      accounts_to_move = owned_accounts.to_a
      provider_items_to_move = provider_items_for_transfer(accounts_to_move)
      moving_default_account = accounts_to_move.any? { |account| account.id == default_account_id }

      account_shares.delete_all

      update!(family: new_family, role: role, default_account: moving_default_account ? default_account : nil)

      accounts_to_move.each do |account|
        account.update!(family: new_family)
      end

      AccountStatement.where(account: accounts_to_move).update_all(family_id: new_family.id, updated_at: Time.current) if accounts_to_move.any?

      provider_items_to_move.each do |provider_item|
        provider_item.update!(family: new_family)
      end

      new_family.auto_share_existing_accounts_with(self)
    end
  end

  def provider_items_for_transfer(accounts_to_move)
    account_ids_to_move = accounts_to_move.map(&:id)
    provider_items = accounts_to_move.flat_map do |account|
      account.account_providers.includes(:provider).filter_map do |account_provider|
        provider_item_for(account_provider.provider)
      end
    end.uniq

    provider_items.each do |provider_item|
      linked_account_ids = provider_item.accounts.map(&:id)
      next if linked_account_ids.all? { |account_id| account_ids_to_move.include?(account_id) }

      errors.add(:base, :provider_item_has_other_accounts)
      raise ActiveRecord::RecordInvalid, self
    end

    provider_items
  end

  def provider_item_for(provider)
    item_association = provider.class.reflect_on_all_associations(:belongs_to).find do |association|
      association.name.to_s.end_with?("_item") && provider.respond_to?(association.name)
    end

    provider.public_send(item_association.name) if item_association
  end

  def purge
    if last_user_in_family?
      family.destroy
    else
      reassign_owned_accounts!
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
    raise ArgumentError, "OTP secret must be set before enabling MFA" if otp_secret.blank?

    backup_codes = generate_backup_codes

    # Store bcrypt digests only; this Postgres array cannot use AR encryption.
    update!(
      otp_required: true,
      otp_backup_codes: backup_codes.map { |code| digest_backup_code(code) }
    )

    backup_codes
  end

  def disable_mfa!
    transaction do
      update!(
        otp_secret: nil,
        otp_required: false,
        otp_backup_codes: []
      )
      webauthn_credentials.destroy_all
    end
  end

  def verify_otp?(code)
    return false if otp_secret.blank?

    normalized_code = normalize_mfa_code(code)
    return false if normalized_code.blank?
    return true if totp.verify(normalized_code, drift_behind: 15)
    return false unless backup_code_input?(normalized_code)

    consume_backup_code!(normalized_code)
  end

  def provisioning_uri
    return nil unless otp_secret.present?
    totp.provisioning_uri(email)
  end

  def ensure_webauthn_id!
    return webauthn_id if webauthn_id.present?

    with_lock do
      update!(webauthn_id: WebAuthn.generate_user_id) unless webauthn_id.present?
    end

    webauthn_id
  end

  def webauthn_enabled?
    otp_required? && webauthn_credentials.exists?
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

  def default_account_for_transactions
    return nil unless default_account_id.present?

    account = default_account
    return nil unless account&.eligible_for_transaction_default? && account.family_id == family_id

    account
  end

  # Dashboard preferences management
  def dashboard_section_collapsed?(section_key)
    preferences&.dig("collapsed_sections", section_key) == true
  end

  def dashboard_section_order
    preferences&.[]("section_order") || default_dashboard_section_order
  end

  # Per-widget height preset override ("compact" | "auto" | "tall"); nil = use default.
  def dashboard_section_height(section_key)
    preferences&.dig("dashboard_section_layout", section_key, "height")
  end

  # Per-widget column-span override ("single" | "full"); nil = use default.
  def dashboard_section_width(section_key)
    preferences&.dig("dashboard_section_layout", section_key, "col_span")
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
          # deep_merge so a partial update of one nested dimension (e.g. a widget's
          # col_span) doesn't clobber a sibling dimension (e.g. its height).
          updated_prefs[key] = updated_prefs[key].deep_merge(value)
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
  def show_split_grouped?
    preferences&.dig("show_split_grouped") != false
  end

  def dashboard_two_column?
    preferences&.dig("dashboard_two_column") == true
  end

  def disable_modal_click_outside?
    preferences&.dig("disable_modal_click_outside") == true
  end

  def preview_features_enabled?
    preferences&.dig("preview_features_enabled") == true
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

      if new_record? && member? && !ai_available?
        self.show_ai_sidebar = false
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
      %w[insights_feed cashflow_sankey outflows_donut net_worth_chart balance_sheet]
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

    def reassign_owned_accounts!
      account_ids = owned_accounts.pluck(:id)
      return if account_ids.empty?

      new_owner = family.users.where.not(id: id)
                        .find_by(role: %w[admin super_admin]) ||
                  family.users.where.not(id: id)
                        .order(:created_at).first

      return unless new_owner

      Account.where(id: account_ids).update_all(owner_id: new_owner.id)
      # Remove shares the new owner had for these accounts (they now own them)
      AccountShare.where(account_id: account_ids, user_id: new_owner.id).delete_all
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

    def consume_backup_code!(normalized_code)
      consumed = false

      transaction do
        lock!

        if otp_backup_codes.present?
          matching_index = otp_backup_codes.index do |stored_code|
            backup_code_matches?(stored_code, normalized_code)
          end

          if matching_index
            remaining_codes = otp_backup_codes.dup
            remaining_codes.delete_at(matching_index)
            update!(otp_backup_codes: remaining_codes)
            consumed = true
          end
        end
      end

      consumed
    end

    def generate_backup_codes
      MFA_BACKUP_CODE_COUNT.times.map { SecureRandom.hex(8) }
    end

    def digest_backup_code(code)
      BCrypt::Password.create(normalize_mfa_code(code), cost: backup_code_digest_cost).to_s
    end

    def backup_code_matches?(stored_code, normalized_code)
      if backup_code_digest?(stored_code)
        return false unless backup_code_input?(normalized_code)

        BCrypt::Password.new(stored_code).is_password?(normalized_code)
      else
        # Legacy plaintext codes are accepted once so existing MFA users are
        # not locked out after backup-code hashing ships.
        ActiveSupport::SecurityUtils.secure_compare(stored_code.to_s, normalized_code)
      end
    rescue BCrypt::Errors::InvalidHash
      false
    end

    def backup_code_digest?(stored_code)
      stored_code.to_s.start_with?("$2a$", "$2b$", "$2y$")
    end

    def normalize_mfa_code(code)
      code.to_s.strip.downcase
    end

    def backup_code_input?(code)
      backup_code_candidate?(code) || legacy_plaintext_backup_code_candidate?(code)
    end

    def backup_code_candidate?(code)
      code.to_s.match?(/\A[0-9a-f]{16}\z/)
    end

    def legacy_plaintext_backup_code_candidate?(code)
      code.to_s.match?(/\A[0-9a-f]{8}\z/)
    end

    def backup_code_digest_cost
      ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    end
end
