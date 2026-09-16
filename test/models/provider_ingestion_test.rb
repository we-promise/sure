require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderIngestionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "shared provider credentials always encrypt even when legacy encryption is optional" do
    with_provider_encryption do
      ProviderConnection.stubs(:encryption_ready?).returns(false)
      connection = create_provider_connection

      assert_equal "private-provider-token", connection.reload.credentials.fetch("access_token")
      assert_provider_column_encrypted(connection, :credentials, "private-provider-token")
    end
  end

  test "shared provider writes require usable encryption configuration" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(false)
    connection = ProviderConnection.new(family: families(:dylan_family), provider_key: "up", name: "Test")

    assert_not connection.valid?
    assert_includes connection.errors[:base], "Active Record encryption must be configured before storing provider data"
  end

  test "direct credential replacement advances its revision once even after repeated validation" do
    with_provider_encryption do
      connection = create_provider_connection
      connection.assign_attributes(credentials: { "access_token" => "replacement-private-token" })
      2.times { assert connection.valid? }
      assert_equal 1, connection.credential_revision
      connection.save!
      assert_equal 1, connection.reload.credential_revision
      assert_provider_column_encrypted(connection, :credentials, "replacement-private-token")
    end
  end

  test "explicit credential store revision increments are accepted without a second increment" do
    with_provider_encryption do
      connection = create_provider_connection
      connection.update!(credentials: { "access_token" => "replacement-private-token" }, credential_revision: 1)
      assert_equal 1, connection.reload.credential_revision
      connection.update!(name: "Renamed connection")
      connection.update!(credentials: connection.credentials.deep_dup)
      assert_equal 1, connection.reload.credential_revision
    end
  end

  test "credential revisions cannot skip during replacement or decrease after publication" do
    with_provider_encryption do
      connection = create_provider_connection
      connection.assign_attributes(credentials: { "access_token" => "replacement-private-token" }, credential_revision: 2)
      assert_not connection.valid?
      assert connection.errors[:credential_revision].present?
      connection.reload.update!(credentials: { "access_token" => "replacement-private-token" })
      connection.credential_revision = 0
      assert_not connection.valid?
      assert connection.errors[:credential_revision].present?
    end
  end

  test "connection provider identity and tenant cannot be reassigned" do
    with_provider_encryption do
      connection = create_provider_connection
      connection.assign_attributes(family: families(:empty), provider_key: "plaid")

      assert_not connection.valid?
      assert connection.errors[:family_id].present?
      assert connection.errors[:provider_key].present?
    end
  end

  test "migration copies are excluded from scheduling until activation" do
    with_provider_encryption do
      connection = create_provider_connection
      assert_includes ProviderConnection.syncable, connection

      control = ProviderMigrationControl.create!(
        family: connection.family, provider_connection: connection, provider_key: "up",
        legacy_type: "UpItem", legacy_id: SecureRandom.uuid, state: "copying"
      )
      %w[legacy copying shadow quiescing rollback_pending failed].each do |state|
        control.update!(state: state)
        assert_not_includes ProviderConnection.syncable, connection
      end
      %w[active retired].each do |state|
        control.update!(state: state)
        assert_includes ProviderConnection.syncable, connection
      end
      connection.update!(scheduled_for_deletion: true)
      assert_not_includes ProviderConnection.syncable, connection
    end
  end

  test "account identity is namespaced by connection and institution" do
    with_provider_encryption do
      first_connection = create_provider_connection
      second_connection = create_provider_connection
      create_external_account(first_connection, external_id: "account-1", identity_namespace: "institution-a")
      create_external_account(first_connection, external_id: "account-1", identity_namespace: "institution-b")
      create_external_account(second_connection, external_id: "account-1", identity_namespace: "institution-a")
      duplicate = first_connection.external_accounts.build(
        external_id: "account-1", identity_namespace: "institution-a", name: "Duplicate", currency: "USD"
      )

      assert_not duplicate.valid?
      assert duplicate.errors[:external_id].present?
      assert_database_rejects(duplicate, error_class: ActiveRecord::RecordNotUnique)
    end
  end

  test "account facing routing keeps the shared account after legacy retirement" do
    with_provider_encryption do
      connection = create_provider_connection
      control = ProviderMigrationControl.create!(family: connection.family, provider_connection: connection,
        provider_key: "up", legacy_type: "UpItem", legacy_id: SecureRandom.uuid, state: "retired")
      external = create_external_account(connection)
      link = AccountProvider.create!(account: accounts(:depository), external_account: external)

      assert_equal external, link.effective_provider
      control.update!(state: "shadow")
      assert_nil link.reload.effective_provider
    end
  end

  test "unresolved account identity can be repaired once without replacing durable account identity" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection, external_id: nil, status: "identity_unresolved")
      external.update!(external_id: "resolved-source-id", status: "active")
      external.external_id = "replacement-source-id"

      assert_not external.valid?
      assert external.errors[:external_id].present?
    end
  end

  test "account tenant and provider ownership are enforced by the database" do
    with_provider_encryption do
      connection = create_provider_connection
      external = connection.external_accounts.build(
        family: families(:empty), provider_key: "up", external_id: "foreign-account", name: "Foreign", currency: "USD"
      )

      assert_not external.valid?
      assert external.errors[:provider_connection].present?
      assert_database_rejects(external)
    end
  end

  test "sensitive account details remain encrypted" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection, sensitive_details: { "iban" => "private-iban-probe" })

      assert_equal "private-iban-probe", external.reload.sensitive_details.fetch("iban")
      assert_provider_column_encrypted(external, :sensitive_details, "private-iban-probe")
    end
  end

  test "authorizations share external accounts without redefining account identity" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      first = connection.provider_authorizations.create!(external_id: "consent-1", credentials: { "token" => "private-consent-token" })
      second = connection.provider_authorizations.create!(external_id: "consent-2")
      [ first, second ].each do |authorization|
        ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: external)
      end

      assert_equal [ first.id, second.id ].sort, external.provider_authorizations.ids.sort
      assert_equal "private-consent-token", first.reload.credentials.fetch("token")
      assert_provider_column_encrypted(first, :credentials, "private-consent-token")
      assert first.usable?
      first.update!(expires_at: 1.second.ago)
      assert_not first.usable?
      second.update!(status: "revoked")
      assert_not second.usable?
    end
  end

  test "authorization cannot include accounts from a different connection in the same family" do
    with_provider_encryption do
      first = create_provider_connection
      second = create_provider_connection
      authorization = first.provider_authorizations.create!
      foreign_account = create_external_account(second)
      membership = ProviderAuthorizationAccount.new(provider_authorization: authorization, external_account: foreign_account)

      assert_not membership.valid?
      assert membership.errors[:external_account].present?
      assert_database_rejects(membership)
    end
  end

  test "captured batch payload and source context cannot be rewritten" do
    with_provider_encryption do
      connection = create_provider_connection
      batch = create_provider_batch(connection, payload: { "private_description" => "sensitive-transaction-probe" })
      assert_provider_column_encrypted(batch, :payload, "sensitive-transaction-probe")
      batch.update!(status: "applied", applied_at: Time.current)
      assert batch.reload.applied?

      batch.payload = { "records" => [ "replacement" ] }
      batch.writer_epoch += 1
      assert_not batch.valid?
      assert batch.errors[:payload].present?
      assert batch.errors[:writer_epoch].present?
    end
  end

  test "original provider evidence is encrypted with the immutable canonical batch" do
    with_provider_encryption do
      page = Provider::AccountData::Page.new(
        records: [], complete: true, evidence: { "response" => { "account_number" => "private-source-number", "balance" => BigDecimal("12.34567890123456789") } }
      )
      batch = create_provider_batch(create_provider_connection, payload: Ingestion::Codec.dump(page))

      assert_provider_column_encrypted(batch, :payload, "private-source-number")
      replayed = Ingestion::Codec.load(batch.reload.payload)
      assert_equal page.evidence, replayed.evidence
      refute_includes replayed.inspect, "private-source-number"
    end
  end

  test "batch retry identity is unique within a family" do
    with_provider_encryption do
      connection = create_provider_connection
      batch = create_provider_batch(connection, idempotency_key: "stable-page-key")
      duplicate = batch.dup

      assert_not duplicate.valid?
      assert duplicate.errors[:idempotency_key].present?
      assert_database_rejects(duplicate, error_class: ActiveRecord::RecordNotUnique)
    end
  end

  test "provider batches require a sync owned by their connection" do
    with_provider_encryption do
      first = create_provider_connection
      second = create_provider_connection
      batch = first.ingestion_batches.build(
        origin_kind: "provider", sync: second.syncs.create!, stream: "accounts",
        idempotency_key: SecureRandom.uuid, writer_epoch: 0, payload: {}
      )

      assert_not batch.valid?
      assert batch.errors[:sync].present?
      assert_database_rejects(batch)
    end
  end

  test "migration payloads preserve history without inventing a successful sync" do
    with_provider_encryption do
      connection = create_provider_connection
      batch = connection.ingestion_batches.create!(
        origin_kind: "migration", stream: "legacy_payloads", idempotency_key: "legacy-item-v1",
        payload: { "raw_transactions_payload" => [ { "id" => "legacy-transaction" } ] }
      )

      assert_nil batch.sync_id
      assert_nil batch.writer_epoch
      assert_equal "unknown", batch.mode
      assert_not batch.complete?
      assert_equal "legacy-transaction", batch.reload.payload.fetch("raw_transactions_payload").first.fetch("id")
    end
  end

  test "file batches retain import ownership without requiring a provider connection" do
    with_provider_encryption do
      batch = IngestionBatch.create!(
        import: imports(:transaction), origin_kind: "file", stream: "transactions",
        idempotency_key: "file-import-v1", status: "review_required", payload: { "rows" => [] }
      )

      assert_equal imports(:transaction).family_id, batch.family_id
      assert_nil batch.provider_connection_id
      assert batch.review_required?

      foreign = batch.dup
      foreign.family = families(:empty)
      foreign.idempotency_key = "foreign-import"
      assert_not foreign.valid?
      assert foreign.errors[:import].present?
      assert_database_rejects(foreign)
    end
  end

  test "unknown coverage cannot be declared complete" do
    with_provider_encryption do
      batch = create_provider_batch(create_provider_connection)
      candidate = batch.dup
      candidate.idempotency_key = SecureRandom.uuid
      candidate.mode = "unknown"

      assert_not candidate.valid?
      assert candidate.errors[:complete].present?
      assert_database_rejects(candidate, error_class: ActiveRecord::StatementInvalid)
    end
  end

  test "checkpoint advances only to an applied batch for its exact resource scope" do
    with_provider_encryption do
      connection = create_provider_connection
      batch = create_provider_batch(connection)
      checkpoint = connection.provider_sync_checkpoints.build(
        ingestion_batch: batch, stream: "accounts", cursor: "private-resume-cursor", state: { "offset" => "private-state-probe" }
      )

      assert_not checkpoint.valid?
      assert checkpoint.errors[:ingestion_batch].present?
      batch.update!(status: "applied", applied_at: Time.current)
      checkpoint.save!
      assert_equal "private-resume-cursor", checkpoint.reload.cursor
      assert_provider_column_encrypted(checkpoint, :cursor, "private-resume-cursor")
      assert_provider_column_encrypted(checkpoint, :state, "private-state-probe")

      checkpoint.stream = "transactions"
      assert_not checkpoint.valid?
      assert checkpoint.errors[:ingestion_batch].present?
    end
  end

  test "checkpoint ownership cannot cross connections" do
    with_provider_encryption do
      first = create_provider_connection
      second = create_provider_connection
      batch = create_provider_batch(second)
      batch.update!(status: "applied", applied_at: Time.current)
      checkpoint = first.provider_sync_checkpoints.build(ingestion_batch: batch, stream: "accounts")

      assert_not checkpoint.valid?
      assert checkpoint.errors[:ingestion_batch].present?
      assert_database_rejects(checkpoint)
    end
  end

  test "migration mapping is stable and must belong to its migration connection" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      control = ProviderMigrationControl.create!(
        family: connection.family, provider_connection: connection, provider_key: "up",
        legacy_type: "UpItem", legacy_id: SecureRandom.uuid
      )
      mapping = control.provider_migration_mappings.create!(
        legacy_type: "UpAccount", legacy_id: SecureRandom.uuid,
        role: "external_account", external_account: external
      )
      assert_equal external, mapping.target
      mapping.update!(source_checksum: "audit-hash", verified_at: Time.current)
      mapping.external_account = create_external_account(create_provider_connection)

      assert_not mapping.valid?
      assert mapping.errors[:role].present?
      assert mapping.errors[:external_account_id].present?
    end
  end

  test "migration mapping rejects ambiguous target roles in the database" do
    with_provider_encryption do
      connection = create_provider_connection
      control = ProviderMigrationControl.create!(
        family: connection.family, provider_connection: connection, provider_key: "up",
        legacy_type: "UpItem", legacy_id: SecureRandom.uuid
      )
      mapping = control.provider_migration_mappings.build(
        legacy_type: "UpAccount", legacy_id: SecureRandom.uuid, role: "external_account",
        external_account: create_external_account(connection), provider_connection: connection
      )

      assert_not mapping.valid?
      assert mapping.errors[:role].present?
      assert_database_rejects(mapping, error_class: ActiveRecord::StatementInvalid)
    end
  end
end
