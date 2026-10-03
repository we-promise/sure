require "test_helper"

class EncryptableTest < ActiveSupport::TestCase
  class TestRecord
    include Encryptable
  end

  test "encryption_ready? delegates to ActiveRecordEncryptionConfig.ready?" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    assert TestRecord.encryption_ready?

    ActiveRecordEncryptionConfig.stubs(:ready?).returns(false)
    assert_not TestRecord.encryption_ready?
  end

  test "encryption_ready? is true for the SECRET_KEY_BASE auto-generated runtime path" do
    # Regression test for issue #3142: encryption_ready? must recognize keys
    # derived from SECRET_KEY_BASE and loaded into
    # Rails.application.config.active_record.encryption at boot, not just
    # explicit ACTIVE_RECORD_ENCRYPTION_* env vars or Rails credentials.
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:runtime_configured?).returns(true)

    assert TestRecord.encryption_ready?
  end

  test "encryption_ready? is false when neither explicit nor runtime config is present" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:runtime_configured?).returns(false)

    assert_not TestRecord.encryption_ready?
  end
end
