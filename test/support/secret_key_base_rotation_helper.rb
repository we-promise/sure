module SecretKeyBaseRotationHelper
  # Simulates a changed SECRET_KEY_BASE for everything that derives keys
  # through Rails.application.key_generator.
  def with_rotated_secret_key_base
    rotated = ActiveSupport::CachingKeyGenerator.new(
      ActiveSupport::KeyGenerator.new(SecureRandom.hex(64), iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA256)
    )
    Rails.application.stubs(:key_generator).returns(rotated)
    yield
  ensure
    Rails.application.unstub(:key_generator)
  end
end
