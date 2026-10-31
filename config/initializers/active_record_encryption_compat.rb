# frozen_string_literal: true

# Operators enabling ActiveRecord encryption on an existing self-hosted
# database can set ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA=true
# so rows written before encryption was configured stay readable while
# they are backfilled (re-save records, or call #encrypt on each).
require Rails.root.join("lib/active_record_encryption_config").to_s

if ActiveRecordEncryptionConfig.complete_env? &&
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA", false))
  Rails.application.config.active_record.encryption.support_unencrypted_data = true
  Rails.application.config.active_record.encryption.extend_queries = true
end
