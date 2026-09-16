require "stringio"
require_relative "identity_bootstrap_test_helper"

module RetainedLogoTestHelper
  include ActiveJob::TestHelper
  include IdentityBootstrapTestHelper

  LogoContext = Data.define(:family, :item, :account, :source, :control, :connection, :blob, :bytes, :copier)

  def with_retained_logo(provider_key: "up", bytes: ("\x00\xFFlogo-data".b * 250), sources: true)
    with_provider_encryption do
      family = families(:dylan_family)
      item = case provider_key
      when "up"
        UpItem.create!(family: family, name: "Retained logo", access_token: "private-logo-token")
      when "plaid"
        PlaidItem.create!(family: family, name: "Retained logo", access_token: "private-logo-token",
          plaid_id: SecureRandom.uuid, plaid_region: "eu")
      else
        raise ArgumentError, "Unsupported retained logo fixture"
      end
      account = family.accounts.create!(name: "Retained logo account", currency: "USD", balance: 123, accountable: Depository.new)
      blob = connection = nil
      begin
        if bytes
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "retained-private-logo.png", content_type: "image/png", identify: false)
          item.logo.attach(blob)
        end
        if sources
          source = if provider_key == "up"
            item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD", current_balance: 123, raw_transactions_payload: [])
          else
            item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Checking", currency: "USD", plaid_type: "depository", current_balance: 123)
          end
          link = AccountProvider.create!(account: account, provider: source)
          identity = provider_key == "up" ? { source: "up", external_id: "up_logo-retained" } : { plaid_id: "plaid-logo-retained" }
          account.entries.create!(**identity, name: "Original financial description", date: Date.current, amount: 10,
            currency: "USD", entryable: Transaction.new)
        end
        copier = Provider::AccountData::MigrationCopier.new(provider_key: provider_key, legacy_item_id: item.id, batch_size: 1)
        control = nil
        15.times do
          control = copier.run_quiesced.reload
          break if control.high_water_mark["phase"] == "verified"
        end
        assert_equal "verified", control.high_water_mark["phase"]
        connection = control.provider_connection
        Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "transactions") if link
        clear_enqueued_jobs
        yield LogoContext.new(family: family, item: item, account: account, source: source, control: control,
          connection: connection, blob: blob, bytes: bytes, copier: copier)
      ensure
        ActiveStorage::Attachment.where(record_type: "ProviderConnection", record_id: connection.id).delete_all if connection
        ActiveStorage::Attachment.where(record_type: item.class.name, record_id: item.id).delete_all
        cleanup_identity_source(item, account)
        blob&.purge
        clear_enqueued_jobs
      end
    end
  end

  def logo_copier(context, **options)
    Provider::AccountData::AuxiliaryCopier.for(control: context.control, chunks_per_run: 1, chunk_bytes: 1024, **options)
  end

  def finish_retained_logo(context, expected_context: nil)
    30.times do
      result = logo_copier(context).run_retained(family: context.family, expected_context: expected_context)
      expected_context ||= result.context
      return result if result.complete?
    end
    flunk "Retained logo did not finish within fixture bounds"
  end

  def logo_checkpoint(context)
    context.connection.provider_sync_checkpoints.find_by!(stream: Provider::AccountData::AuxiliaryCopier::STREAM)
  end

  def logo_batches(context)
    context.connection.ingestion_batches.where(stream: Provider::AccountData::AuxiliaryCopier::STREAM).order(:sequence)
  end

  def logo_snapshot(context)
    { checkpoint: logo_checkpoint(context).attributes, batches: logo_batches(context).map(&:attributes),
      attachments: ActiveStorage::Attachment.where(record_id: [ context.item.id, context.connection.id ]).order(:id).map(&:attributes) }
  end
end
