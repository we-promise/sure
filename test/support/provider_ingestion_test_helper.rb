module ProviderIngestionTestHelper
  def with_provider_encryption
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    key_provider = ActiveRecord::Encryption::KeyProvider.new("provider-ingestion-test-key-0001")
    previous_signing = Rails.application.config.x.provider_identity_signing
    Rails.application.config.x.provider_identity_signing = {
      active_key_id: "test-v1", keys: { "test-v1" => [ "i" * 32 ].pack("m0") }
    }
    ActiveRecord::Encryption.with_encryption_context(key_provider: key_provider) { yield }
  ensure
    Rails.application.config.x.provider_identity_signing = previous_signing
  end

  def create_provider_connection(**attributes)
    ProviderConnection.create!({
      family: families(:dylan_family), provider_key: "up", name: "Test connection",
      credentials: { "access_token" => "private-provider-token" }
    }.merge(attributes))
  end

  def create_external_account(connection, **attributes)
    connection.external_accounts.create!({
      external_id: SecureRandom.uuid, name: "Checking", currency: "USD"
    }.merge(attributes))
  end

  def create_provider_batch(connection, **attributes)
    sync = attributes.delete(:sync) || connection.syncs.create!
    # Ledger fixtures capture their binding when the evidence is created, before
    # the test can change a link or policy. Explicit empty bindings exercise old
    # or incomplete captures; the writer must never reconstruct those later.
    if !attributes.key?(:source_binding) && attributes[:external_account] && attributes[:source_policy_version] &&
        %w[transactions balances holdings activities].include?(attributes[:stream])
      external = attributes.fetch(:external_account)
      attributes[:source_binding] = Provider::AccountData::GenerationAccounts.new(connection,
        resource: attributes.fetch(:stream), identity_namespace: external.identity_namespace).capture_one(external)
    end
    connection.ingestion_batches.create!({
      sync: sync, origin_kind: "provider", stream: "accounts", scope_key: "connection",
      idempotency_key: SecureRandom.uuid, writer_epoch: connection.writer_epoch,
      mode: "snapshot", complete: true, payload: { "records" => [] }
    }.merge(attributes))
  end

  def assert_provider_column_encrypted(record, column, plaintext)
    raw = ActiveRecord::Base.connection.select_value(
      record.class.where(id: record.id).select(column).to_sql
    )
    assert raw.present?
    assert_not_includes raw.to_s, plaintext
    assert JSON.parse(raw).key?("p"), "expected an Active Record encrypted message"
  end

  def assert_database_rejects(record, error_class: ActiveRecord::InvalidForeignKey)
    assert_raises(error_class) do
      ApplicationRecord.transaction(requires_new: true) { record.save!(validate: false) }
    end
  end
end
