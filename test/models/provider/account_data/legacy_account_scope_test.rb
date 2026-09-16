require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::LegacyAccountScopeTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "Onchain reloads the explicit array in its requested order without adding other assets" do
    with_item("onchain_wallet") do |item|
      first = create_source(item, name: "First")
      second = create_source(item, name: "Second")
      create_source(item, name: "Not selected")
      stale = item.class.find(item.id)
      stale.onchain_wallet_accounts.load
      second.update!(quantity: 8)
      first.quantity = 999 # Unsaved caller state must never reach the processor.
      seen = []
      OnchainWalletAccount::Processor.expects(:new).times(3).with do |record|
        seen << [ record.id, record.quantity ]
        true
      end.returns(mock_processor(:processed))

      result = stale.process_accounts([ second, first, second ])

      assert_equal [ second.id, first.id, second.id ], result.map { |row| row[:onchain_wallet_account_id] }
      assert_equal [ [ second.id, 8 ], [ first.id, 1 ], [ second.id, 8 ] ], seen
      assert result.all? { |row| row[:success] }
    end
  end

  test "a foreign member rejects the whole subset before either provider processes a valid member" do
    %w[onchain_wallet sophtron].each do |provider|
      with_item(provider) do |item|
        [ item.family, families(:empty) ].each do |family|
          with_item(provider, family: family) do |other|
            selected = [ create_source(item), create_source(other) ]
            processor_class(provider).expects(:new).never
            assert_raises(Fence::OwnershipChanged) { process_subset(item, selected) }
          end
        end
      end
    end
  end

  test "deleted and reparented selected rows cannot be silently dropped or processed" do
    %w[onchain_wallet sophtron].each do |provider|
      with_item(provider) do |item|
        with_item(provider) do |other|
          valid = create_source(item)
          deleted = create_source(item)
          moved = create_source(item)
          deleted.class.find(deleted.id).destroy!
          foreign_key = Provider::AccountData::MigrationManifest.for(provider).account_foreign_key
          moved.class.where(id: moved.id).update_all(foreign_key => other.id)
          processor_class(provider).expects(:new).never

          assert_raises(Fence::OwnershipChanged) { process_subset(item, [ valid, deleted ]) }
          assert_raises(Fence::OwnershipChanged) { process_subset(item, [ valid, moved ]) }
        end
      end
    end
  end

  test "scope inputs reject unknown classes new records and non-collections" do
    %w[onchain_wallet sophtron].each do |provider|
      with_item(provider) do |item|
        source = create_source(item)
        processor_class(provider).expects(:new).never
        [ nil, [ source.class.new ], [ accounts(:depository) ], Account.none ].each do |invalid|
          assert_raises(Fence::InvalidSource) { process_subset(item, invalid) }
        end
        assert_raises(Fence::InvalidSource) { Fence.scoped_accounts!(item, [ source ]) }
      end
    end
  end

  test "a legacy financial link cannot escape the admitted item's family" do
    %w[onchain_wallet sophtron].each do |provider|
      with_item(provider) do |item|
        source = create_source(item)
        financial = create_financial_account(item, family: families(:empty))
        AccountProvider.create!(provider: source, account: financial)
        processor_class(provider).expects(:new).never

        assert_raises(Fence::OwnershipChanged) { process_subset(item, [ source ]) }
      ensure
        financial&.destroy!
      end
    end
  end

  test "Sophtron preserves an already loaded limited relation and refreshes its financial fields" do
    with_item("sophtron") do |item|
      create_source(item, name: "A")
      selected = create_source(item, name: "B")
      create_source(item, name: "C")
      relation = item.sophtron_accounts.automatic_sync.order(:name).offset(1).limit(1)
      assert_equal [ selected.id ], relation.load.map(&:id)
      selected.update!(balance: 42)
      create_source(item, name: "AA") # Would shift the offset if the selection were rerun.
      processor = mock_processor(:processed)
      SophtronAccount::Processor.expects(:new).with do |current|
        current.id == selected.id && current.balance == 42 && !current.equal?(selected)
      end.returns(processor)

      result = item.process_accounts(sophtron_accounts_scope: relation)

      assert_equal [ { sophtron_account_id: selected.id, success: true, result: :processed } ], result
    end
  end

  test "a loaded Sophtron scope rejects a selected account that no longer matches its filters" do
    with_item("sophtron") do |item|
      selected = create_source(item)
      relation = item.sophtron_accounts.automatic_sync.order(:id).limit(1).load
      selected.update!(manual_sync: true)
      create_source(item)
      SophtronAccount::Processor.expects(:new).never

      assert_raises(Fence::OwnershipChanged) { item.process_accounts(sophtron_accounts_scope: relation) }
    end
  end

  test "Sophtron's omitted scope retains its linked visible default including manual accounts" do
    with_item("sophtron") do |item|
      automatic = create_source(item)
      manual = create_source(item, manual_sync: true)
      hidden = create_source(item)
      create_source(item) # Unlinked.
      financial = [ create_financial_account(item), create_financial_account(item), create_financial_account(item, status: "disabled") ]
      [ automatic, manual, hidden ].zip(financial).each { |source, account| AccountProvider.create!(provider: source, account: account) }
      seen = []
      SophtronAccount::Processor.expects(:new).twice.with do |current|
        seen << current.id
        true
      end.returns(mock_processor(:processed))

      result = item.process_accounts

      assert_equal [ automatic.id, manual.id ].sort, seen.sort
      assert_equal seen, result.map { |row| row[:sophtron_account_id] }
    ensure
      financial&.each(&:destroy!)
    end
  end

  test "both item entrypoints reject native ownership before scope handling or provider construction" do
    %w[onchain_wallet sophtron].each do |provider|
      with_item(provider) do |item|
        ProviderMigrationControl.create!(family: item.family, provider_key: provider,
          legacy_type: item.class.name, legacy_id: item.id, state: "active")
        processor_class(provider).expects(:new).never
        item.class.const_get(:Importer).expects(:new).never
        import_method = provider == "sophtron" ? :import_latest_sophtron_data : :import_latest_onchain_data

        assert_raises(Fence::OwnershipChanged) { item.public_send(import_method) }
        assert_raises(Fence::OwnershipChanged) { process_subset(item, []) }
      end
    end
  end

  private
    def with_item(provider, family: families(:dylan_family))
      with_provider_encryption do
        item = if provider == "sophtron"
          SophtronItem.create!(family: family, name: "Fenced Sophtron", user_id: "test-user", access_key: "test-key")
        else
          OnchainWalletItem.create!(family: family, name: "Fenced on-chain wallet")
        end
        yield item
      ensure
        if item&.persisted?
          ProviderMigrationControl.where(legacy_type: item.class.name, legacy_id: item.id).destroy_all
          item.destroy!
        end
      end
    end

    def create_source(item, **attributes)
      if item.is_a?(SophtronItem)
        item.sophtron_accounts.create!({ account_id: SecureRandom.uuid, name: "Account", currency: "USD", balance: 1 }.merge(attributes))
      else
        item.onchain_wallet_accounts.create!({ chain: "bitcoin", wallet_address: "test-wallet-#{SecureRandom.uuid}",
          asset_kind: "native", symbol: "BTC", currency: "USD", quantity: 1, decimals: 8, name: "Bitcoin" }.merge(attributes))
      end
    end

    def create_financial_account(item, status: "active", family: item.family)
      Account.create!(family: family, name: "Scoped source account", currency: "USD", balance: 0,
        accountable: Depository.create!, status: status)
    end

    def process_subset(item, subset)
      if item.is_a?(SophtronItem)
        item.process_accounts(sophtron_accounts_scope: subset)
      else
        item.process_accounts(subset)
      end
    end

    def processor_class(provider)
      provider == "sophtron" ? SophtronAccount::Processor : OnchainWalletAccount::Processor
    end

    def mock_processor(result)
      mock("legacy account processor").tap { |processor| processor.stubs(:process).returns(result) }
    end
end
