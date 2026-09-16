require "test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Ingestion::LegacyIdentityAccountBindingTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier
  Evidence = Ingestion::LegacyIdentityEvidence

  test "planners and evidence reject a same family relink even with self consistent current context" do
    each_identity_source do |context, planner|
      old_plan = planner.page.document
      replacement = context.family.accounts.create!(name: "Other financial account", currency: "USD", balance: 0, accountable: Depository.new)
      begin
        context.account.source_policies.delete_all
        context.link.update!(account: replacement)
        Account::SourcePolicy.select!(account: replacement, account_provider: context.link, resource: "transactions")
        assert_equal replacement.id, context.source.reload.current_account.id

        assert_raises(planner.class::InvalidContext) { planner.page }
        assert_raises(planner.class::InvalidContext) { planner.candidate_entry_ids }

        # A caller cannot replace copy-time ownership with a freshly coherent
        # current-link plan, even if it contains no financial rows to write.
        replacement_plan = old_plan.merge("account_id" => replacement.id,
          "account_provider_revision" => context.link.reload.lock_version, "rows" => [])
        assert_raises(Evidence::InvalidEvidence) { seal(context, replacement_plan) }
        assert_empty context.external.provider_connection.ingestion_batches.where(stream: Evidence::STREAM)
        assert_empty SourceRecord.where(external_account: context.external)
      ensure
        replacement.source_policies.delete_all
        context.link.reload.update!(account: context.account) if context.link.persisted?
        replacement.destroy!
      end
    end
  end

  test "financial currency and delegated account context cannot drift after the copy" do
    each_identity_source do |context, planner|
      old_plan = planner.page.document
      context.account.update!(currency: "EUR")

      assert_raises(planner.class::InvalidContext) { planner.page }
      assert_raises(planner.class::InvalidContext) { planner.candidate_entry_ids }
      assert_raises(Evidence::InvalidEvidence) { seal(context, old_plan.merge("account_currency" => "EUR")) }

      context.account.update!(currency: "USD")
      original = context.account.accountable
      replacement = Depository.create!
      begin
        context.account.update!(accountable: replacement)

        assert_raises(planner.class::InvalidContext) { planner.page }
        assert_raises(Evidence::InvalidEvidence) { seal(context, old_plan.merge("accountable_id" => replacement.id)) }
      ensure
        context.account.update!(accountable: original)
        replacement.destroy!
      end
    end
  end

  test "old archives without copy time binding cannot support a report or permanent proof" do
    each_identity_source do |context, planner|
      plan = planner.page.document
      archive = context.copier.snapshot_for(context.mapping)
      assert archive.key?("account_binding")
      Copier.any_instance.stubs(:snapshot_for).returns(archive.except("account_binding"))
      begin
        assert_raises(planner.class::InvalidContext) { planner.page }
        assert_raises(planner.class::InvalidContext) { planner.candidate_entry_ids }
        assert_raises(Evidence::InvalidEvidence) { seal(context, plan) }
        assert_empty context.external.provider_connection.ingestion_batches.where(stream: Evidence::STREAM)
      ensure
        Copier.any_instance.unstub(:snapshot_for)
      end
    end
  end

  test "ordinary financial values and user protections remain editable before identity planning" do
    each_identity_source do |context, planner|
      entry = context.account.entries.sole
      context.account.update!(name: "Renamed financial account", balance: BigDecimal("2345.6789"))
      entry.update!(name: "User description", amount: BigDecimal("98.7654"), user_modified: true,
        import_locked: true, excluded: true, locked_attributes: { "name" => true })
      expected = identity_financial_snapshot(context)

      page = planner.page
      assert page.ready?
      payload = seal(context, page.document)

      assert_equal [ entry.id ], payload.fetch("plan").fetch("rows").map { |row| row.fetch("entry_id") }
      assert_equal expected, identity_financial_snapshot(context)
      assert_equal context.account.id, payload.fetch("admission").fetch("account_id")
      assert_empty context.external.provider_connection.ingestion_batches.where(stream: Evidence::STREAM)
    end
  end

  private
    def each_identity_source
      %w[up plaid].each do |key|
        with_identity_source(provider_key: key, plaid_transactions: [ { transaction_id: "booked", pending: false } ]) do |context|
          identity_entry(context, external_id: key == "up" ? "up_booked" : "booked")
          klass = key == "plaid" ? Provider::AccountData::Plaid::IdentityBootstrapPlan : Provider::AccountData::IdentityBootstrapPlan
          yield context, klass.new(mapping: context.mapping, family: context.family)
        end
      end
    end

    def seal(context, plan)
      Provider::AccountData::LegacyWriterFence.with_exclusive(context.item) do
        ApplicationRecord.transaction do
          Evidence.seal(plan: plan, control: context.control, mapping: context.mapping)
        end
      end
    end
end
