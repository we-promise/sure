require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class SimplefinHoldingsRequestTest < ActiveJob::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Request = SimplefinAccount::HoldingsRequest
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "a serialized queued request publishes the selected holdings outside resolver transactions" do
    with_source do |item, source, account, link, security|
      job = nil
      assert_enqueued_jobs 1, only: SimplefinHoldingsApplyJob do
        job = SimplefinHoldingsApplyJob.enqueue_for(source)
      end
      token = job.arguments.last.fetch(:request)
      claims = Rails.application.message_verifier(Request::PURPOSE).verified(token, purpose: Request::PURPOSE)
      assert_kind_of Hash, claims
      serialized = JSON.parse(JSON.generate(job.serialize))
      %w[raw_holdings_payload market_value shares total_cost].each do |key|
        assert_not_includes claims.to_json, key
      end
      assert_not_includes claims.to_json, security.ticker
      assert_not_includes claims.to_json, item.access_url
      assert_not_includes serialized.to_json, item.access_url
      resolve_with(security) { assert_equal 0, ApplicationRecord.connection.open_transactions }

      assert_difference "account.holdings.count", 1 do
        SimplefinHoldingsApplyJob.deserialize(serialized).perform_now
      end
      holding = account.holdings.find_by!(external_id: "simplefin_current")
      assert_equal link.id, holding.account_provider_id
      assert_equal BigDecimal("2.5"), holding.qty
      assert_equal BigDecimal("250"), holding.amount
      assert_equal BigDecimal("100"), holding.price
      assert_equal BigDecimal("80"), holding.cost_basis
    end
  end

  test "capture performs no security or provider request and closes its publication transaction" do
    with_source do |_item, source, account, _link, _security|
      Security::Resolver.expects(:new).never
      SimplefinItem.any_instance.expects(:simplefin_provider).never
      before = [ source.reload.attributes, account.reload.attributes ]
      token = Request.capture(source)
      assert_kind_of String, token
      assert_equal 0, ApplicationRecord.connection.open_transactions
      Request.from_token(token, source_id: source.id).with_source do |fresh|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal source.id, fresh.id
        assert_equal account.id, fresh.current_account.id
      end
      assert_equal before, [ source.reload.attributes, account.reload.attributes ]
    end
  end

  test "missing malformed oversized and tampered tokens never reach security resolution" do
    with_source do |_item, source, account, _link, _security|
      token = Request.capture(source)
      Security::Resolver.expects(:new).never
      [ nil, "", "not-signed", "#{token}changed", "x" * (Request::MAX_TOKEN_BYTES + 1) ].each do |invalid|
        assert_no_difference "Holding.count" do
          assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: invalid) }
        end
      end
      assert_empty account.holdings
      # A historical source-ID-only request remains invalid even if the current
      # source still has a valid payload. It must not acquire fresh authority.
      assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id) }
    end
  end

  test "a token for another source cannot authorize an existing row" do
    with_source do |item, source, _account, _link, _security|
      token = Request.capture(source)
      other = item.simplefin_accounts.create!(name: "Other source", account_id: SecureRandom.uuid,
        currency: "USD", account_type: "investment", current_balance: 20)
      Security::Resolver.expects(:new).never
      assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(other.id, request: token) }
    end
  end

  test "capture does not enqueue an unlinked noninvestment or empty source" do
    [ :unlinked, :noninvestment, :empty ].each do |state|
      with_source do |_item, source, account, link, _security|
        case state
        when :unlinked then link.destroy!
        when :noninvestment then account.update!(accountable: Depository.new)
        when :empty then source.update!(raw_holdings_payload: [])
        end
        assert_nil Request.capture(source)
        assert_no_enqueued_jobs { assert_nil SimplefinHoldingsApplyJob.enqueue_for(source) }
      end
    end
  end

  test "a deleted source remains a no-op for old or missing requests" do
    with_source do |_item, source, _account, link, _security|
      token = Request.capture(source)
      id = source.id
      link.destroy!
      source.destroy!
      Security::Resolver.expects(:new).never
      assert_no_difference "Holding.count" do
        SimplefinHoldingsApplyJob.perform_now(id, request: token)
        SimplefinHoldingsApplyJob.perform_now(id)
      end
    end
  end

  test "reparenting before execution cannot adopt a new item or family" do
    [ false, true ].each do |foreign|
      with_source do |item, source, account, _link, _security|
        token = Request.capture(source)
        other_family = Family.create!(name: "Foreign holdings") if foreign
        other = SimplefinItem.create!(family: other_family || item.family, name: "Replacement item", access_url: "https://example.com/replacement")
        source.update_columns(simplefin_item_id: other.id)
        Security::Resolver.expects(:new).never
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        assert_empty account.holdings
      ensure
        source&.update_columns(simplefin_item_id: item.id) if item
        other&.destroy!
        other_family&.destroy!
      end
    end
  end

  test "unlink relink and replacement link before execution cannot reuse the original request" do
    %i[unlink relink replace revision].each do |change|
      with_source do |_item, source, account, link, _security|
        token = Request.capture(source)
        case change
        when :unlink then link.destroy!
        when :relink
          other = Account.create!(family: account.family, name: "Replacement account", currency: "USD", balance: 50, accountable: Investment.new)
          link.update!(account: other)
        when :replace
          link.destroy!
          AccountProvider.create!(account: account, provider: source)
        when :revision then link.update!(family_id: account.family_id)
        end
        Security::Resolver.expects(:new).never
        assert_no_difference "Holding.count" do
          assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        end
        assert_empty account.holdings
      end
    end
  end

  test "financial currency delegated identity and direct-link drift reject before execution" do
    %i[currency delegated direct].each do |change|
      with_source do |_item, source, account, _link, _security|
        token = Request.capture(source)
        case change
        when :currency then account.update!(currency: "EUR")
        when :delegated then account.update!(accountable: Crypto.new)
        when :direct then account.update!(simplefin_account_id: source.id)
        end
        Security::Resolver.expects(:new).never
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        assert_empty account.holdings
      end
    end
  end

  test "payload name institution source type and remote identity changes require a newly captured request" do
    %i[payload name institution type remote_id].each do |change|
      with_source do |_item, source, account, _link, _security|
        token = Request.capture(source)
        attributes = case change
        when :payload then { raw_holdings_payload: source.raw_holdings_payload.map { |row| row.merge("market_value" => "300") } }
        when :name then { name: "Crypto account" }
        when :institution then { org_data: { "name" => "Vanguard" } }
        when :type then { account_type: "crypto" }
        when :remote_id then { account_id: SecureRandom.uuid }
        end
        source.update!(attributes)
        Security::Resolver.expects(:new).never
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        assert_empty account.holdings
      end
    end
  end

  test "scheduled account or item deletion invalidates existing requests and prevents recapture" do
    %i[account item].each do |target|
      with_source do |item, source, account, _link, _security|
        token = Request.capture(source)
        target == :account ? account.update_columns(status: "pending_deletion") : item.update_columns(scheduled_for_deletion: true)
        Security::Resolver.expects(:new).never
        assert_no_difference "Holding.count" do
          assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        end
        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.enqueue_for(source) }
        end
        assert_empty account.holdings
      end
    end
  end

  test "a credential replacement invalidates queued holdings even when cached financial input is unchanged" do
    with_source do |item, source, account, _link, _security|
      token = Request.capture(source)
      original_url = item.access_url
      original_revision = item.credential_revision
      item.update_columns(access_url: "https://example.com/reconnected")
      item.update_columns(access_url: original_url)
      assert_operator item.reload.credential_revision, :>, original_revision
      Security::Resolver.expects(:new).never
      assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
      assert_empty account.holdings
    end
  end

  test "a payload changed during security resolution rejects before any holding publication" do
    with_source do |_item, source, account, _link, security|
      token = Request.capture(source)
      future = account.holdings.create!(security: security, external_id: "keep_future", date: Date.current + 1,
        currency: "USD", qty: 1, price: 12, amount: 12)
      before = future.attributes
      resolve_with(security) do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        source.update!(raw_holdings_payload: source.raw_holdings_payload.map { |row| row.merge("shares" => "500") })
      end
      assert_no_difference "Holding.count" do
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
      end
      assert_equal before, future.reload.attributes
      assert_not account.holdings.exists?(external_id: "simplefin_current")
    end
  end

  test "a holdings policy revision cannot be silently rebound by a queued request" do
    with_source do |_item, source, account, link, _security|
      selected = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "holdings")
      token = Request.capture(source)
      selected.update!(active: false)
      replacement = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "holdings")
      assert_not_equal selected.id, replacement.id
      Security::Resolver.expects(:new).never
      assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
      assert_empty account.holdings
    end
  end

  test "writer epoch changes and native ownership deny a previously valid request" do
    [ :epoch, :quiescing, :active, :retired ].each do |change|
      with_source do |item, source, account, _link, _security|
        control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin", legacy_type: "SimplefinItem", legacy_id: item.id)
        token = Request.capture(source)
        change == :epoch ? control.update!(writer_epoch: control.writer_epoch + 1) : control.update!(state: change.to_s)
        Security::Resolver.expects(:new).never
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        assert_empty account.holdings
      end
    end
  end

  test "the originating Sync and completed ancestors remain valid when they finish normally" do
    with_source do |item, source, account, _link, security|
      parent = item.family.syncs.create!(status: "syncing")
      sync = item.syncs.create!(parent: parent, status: "syncing")
      token = Request.capture(source, sync: sync)
      sync.update_columns(status: "completed")
      parent.update_columns(status: "completed")
      resolve_with(security) { assert_equal 0, ApplicationRecord.connection.open_transactions }
      assert_difference "account.holdings.count", 1 do
        SimplefinHoldingsApplyJob.perform_now(source.id, request: token)
      end
    end
  end

  test "cancellation of the originating Sync or any retained ancestor rejects queued holdings" do
    %i[self parent grandparent].each do |level|
      with_source do |item, source, account, _link, _security|
        grandparent = item.family.syncs.create!(status: "syncing")
        parent = item.family.syncs.create!(parent: grandparent, status: "syncing")
        sync = item.syncs.create!(parent: parent, status: "syncing")
        token = Request.capture(source, sync: sync)
        { self: sync, parent: parent, grandparent: grandparent }.fetch(level).update_columns(cancel_requested_at: Time.current)
        Security::Resolver.expects(:new).never
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        assert_empty account.holdings
      end
    end
  end

  test "a changed missing or failed originating Sync cannot be replaced with current lineage" do
    %i[parent deleted failed].each do |change|
      with_source do |item, source, account, _link, _security|
        parent = item.family.syncs.create!(status: "syncing")
        sync = item.syncs.create!(parent: parent, status: "syncing")
        token = Request.capture(source, sync: sync)
        case change
        when :parent then sync.update_columns(parent_id: item.family.syncs.create!(status: "syncing").id)
        when :deleted then sync.delete
        when :failed then sync.update_columns(status: "failed")
        end
        Security::Resolver.expects(:new).never
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: token) }
        assert_empty account.holdings
      end
    end
  end

  test "a Sync owned by another item cannot be used when capturing a request" do
    with_source do |item, source, _account, _link, _security|
      other = SimplefinItem.create!(family: item.family, name: "Another item", access_url: "https://example.com/other")
      sync = other.syncs.create!
      assert_no_enqueued_jobs do
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.enqueue_for(source, sync: sync) }
      end
    ensure
      other&.destroy!
    end
  end

  private
    def resolve_with(security, &during_lookup)
      resolver = Object.new
      resolver.define_singleton_method(:resolve) do
        during_lookup&.call
        security
      end
      Security::Resolver.expects(:new).with(security.ticker).returns(resolver)
    end

    def payload(security)
      { "id" => "current", "symbol" => security.ticker, "description" => "Private holding description",
        "shares" => "2.5", "market_value" => "250", "total_cost" => "200", "currency" => "USD" }
    end

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN holdings request")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/private-access-token")
        security = Security.create!(ticker: "SF#{SecureRandom.hex(5).upcase}", name: "Request test security", offline: true)
        source = item.simplefin_accounts.create!(name: "Brokerage", account_id: SecureRandom.uuid,
          currency: "USD", account_type: "investment", current_balance: 250, raw_holdings_payload: [ payload(security) ])
        accountable = Investment.new
        account = Account.create!(family: family, name: "Brokerage", currency: "USD", balance: 0, accountable: accountable)
        link = AccountProvider.create!(account: account, provider: source)
        yield item, source, account, link, security
      ensure
        if family&.persisted?
          Account::SourcePolicy.where(family: family).delete_all
          Holding.where(account_id: family.accounts.select(:id)).destroy_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          ProviderMigrationControl.where(family: family).delete_all
          family.accounts.reload.each(&:destroy!)
          Investment.find_by(id: accountable&.id)&.destroy!
          item&.reload&.destroy!
          family.destroy!
        end
        security&.destroy!
      end
    end
end
