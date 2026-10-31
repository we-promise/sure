class ApiKey < ApplicationRecord
  include Encryptable

  belongs_to :user

  # LEGACY: before `key_digest` existed the secret itself was stored in
  # `display_key` (encrypted when ActiveRecord encryption is configured,
  # plaintext otherwise). New keys never write it and nothing authenticates
  # against it. It stays declared (and decryptable) only until the column is
  # dropped in a follow-up release, so a rollback keeps working.
  if encryption_ready?
    encrypts :display_key, deterministic: true
  end

  # Constants
  SOURCES = [ "web", "mobile", "monitoring" ].freeze
  KEY_PREFIX_LENGTH = 8
  DEMO_MONITORING_KEY = "demo_monitoring_key_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6"

  # Class methods

  # One-way digest under which a key is stored and looked up. Keys are 256 bits
  # of randomness (see .generate_secure_key), so an unsalted SHA-256 can't be
  # brute-forced and, unlike a pepper derived from secret_key_base, keeps keys
  # valid when that secret is rotated.
  def self.digest(plain_key)
    OpenSSL::Digest::SHA256.hexdigest(plain_key.to_s)
  end

  DEMO_MONITORING_KEY_DIGEST = digest(DEMO_MONITORING_KEY)

  # Validations
  validates :key_digest, presence: true, uniqueness: true
  validates :name, presence: true
  validates :scopes, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validate :scopes_not_empty
  validate :name_unique_among_active_keys, on: :create

  # Callbacks
  before_validation :ensure_key_digest_from_legacy_display_key
  before_destroy :prevent_demo_monitoring_key_destroy!

  # Scopes
  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  # SECURITY: excluding the demo monitoring key here is also the revocation guard
  # in Settings::ApiKeysController#destroy — a demo key id 404s in `set_api_key`
  # (it is not `.visible`) before it can be revoked. Do NOT broaden this scope to
  # include monitoring keys without adding another explicit destroy guard.
  scope :visible, -> { where("api_keys.key_digest IS NULL OR api_keys.key_digest <> ?", DEMO_MONITORING_KEY_DIGEST) }
  scope :demo_monitoring, -> { where(key_digest: DEMO_MONITORING_KEY_DIGEST) }

  def self.find_by_value(plain_key)
    return nil if plain_key.blank?

    api_key = find_by(key_digest: digest(plain_key))

    # Compatibility fallback during rolling deployments: if an old pod wrote
    # a key after the initial migration backfill, display_key is populated
    # but key_digest is nil. Look it up, backfill on the fly, and use it.
    if api_key.nil? && column_names.include?("display_key")
      legacy_key = find_by(display_key: plain_key, key_digest: nil)
      if legacy_key
        legacy_key.update_columns(
          key_digest: digest(plain_key),
          key_prefix: plain_key.to_s.first(KEY_PREFIX_LENGTH)
        )
        api_key = legacy_key
      end
    end

    api_key if api_key&.active?
  end

  def self.generate_secure_key
    SecureRandom.hex(32)
  end

  # Instance methods
  def active?
    !revoked? && !expired?
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def key_matches?(plain_key)
    return false if plain_key.blank?

    if key_digest.present?
      ActiveSupport::SecurityUtils.secure_compare(key_digest, self.class.digest(plain_key))
    elsif respond_to?(:display_key) && display_key.present?
      ActiveSupport::SecurityUtils.secure_compare(self.class.digest(display_key), self.class.digest(plain_key))
    else
      false
    end
  end

  def revoke!
    raise ActiveRecord::RecordNotDestroyed, "Cannot revoke demo monitoring API key" if demo_monitoring_key?
    update!(revoked_at: Time.current)
  end

  def delete
    raise ActiveRecord::RecordNotDestroyed, "Cannot destroy demo monitoring API key" if demo_monitoring_key?
    super
  end

  def demo_monitoring_key?
    key_matches?(DEMO_MONITORING_KEY)
  end

  def update_last_used!
    update_column(:last_used_at, Time.current)
  end

  # The plain text key, available only on the instance that generated it (i.e.
  # right after creation). It is never persisted, so a record loaded from the
  # database returns nil and the key can't be shown again.
  def plain_key
    key
  end

  # Temporarily store the plain key for creation flow. Assigning it derives the
  # digest and prefix that are persisted in its place, so they are set however
  # the record ends up being saved.
  attr_reader :key

  def key=(plain_key)
    @key = plain_key
    apply_key_digest(plain_key)
  end

  private

    def apply_key_digest(plain_key)
      if plain_key.present?
        self.key_digest = self.class.digest(plain_key)
        self.key_prefix = plain_key.to_s.first(KEY_PREFIX_LENGTH)
      else
        self.key_digest = nil
        self.key_prefix = nil
      end
    end

    def ensure_key_digest_from_legacy_display_key
      if key_digest.blank? && respond_to?(:display_key) && display_key.present?
        apply_key_digest(display_key)
      end
    end

    def scopes_not_empty
      if scopes.blank? || (scopes.is_a?(Array) && (scopes.empty? || scopes.all?(&:blank?)))
        errors.add(:scopes, "must include at least one permission")
      elsif scopes.is_a?(Array) && scopes.length > 1
        errors.add(:scopes, "can only have one permission level")
      elsif scopes.is_a?(Array) && !%w[read read_write].include?(scopes.first)
        errors.add(:scopes, "must be either 'read' or 'read_write'")
      end
    end

    def name_unique_among_active_keys
      return if name.blank? || user.blank?
      scope = user.api_keys.active.visible.where(name: name)
      scope = scope.where.not(id: id) if persisted?
      errors.add(:name, :taken) if scope.exists?
    end

    def prevent_demo_monitoring_key_destroy!
      return unless demo_monitoring_key?

      errors.add(:base, :cannot_destroy_demo_key)
      throw(:abort)
    end
end
