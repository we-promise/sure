# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class TricountItem::ImporterTest < ActiveSupport::TestCase
  include TricountTestHelper

  setup do
    @item = families(:empty).tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    @provider = mock
  end

  def import!
    TricountItem::Importer.new(@item, tricount_provider: @provider).import
  end

  test "each followed tricount becomes a provider account with its members and entries" do
    @provider.expects(:synchronize!).with([ SHARING_TOKEN ])
    @provider.expects(:registry).with(SHARING_TOKEN).returns(tricount_registry)

    import!
    tricount_account = @item.tricount_accounts.sole

    assert_equal [ REGISTRY_UUID, "Weekend trip", "EUR" ], [ tricount_account.tricount_account_id, tricount_account.name, tricount_account.currency ]
    assert_equal [ "Alex", "Sam", "Kim" ], tricount_account.members.map(&:name)
    assert_equal 5, tricount_account.raw_transactions_payload.size
    assert_equal 4, tricount_account.active_entry_count, "the deleted entry is left out"
    assert_not tricount_account.raw_payload.key?("all_registry_entry")
    assert_not_includes [ tricount_account.raw_payload, tricount_account.raw_transactions_payload ].to_json, SHARING_TOKEN,
      "the sharing token grants write access and stays only in the encrypted item"
    assert_nil tricount_account.current_balance, "no member chosen yet"
  end

  test "the tricount's currency is normalised, and an unknown one keeps the last good one" do
    @provider.stubs(:synchronize!)
    in_chf = tricount_entries.map(&:deep_dup).each { |entry| entry["RegistryEntry"]["amount"]["currency"] = "CHF" }
    @provider.stubs(:registry).returns(tricount_registry(entries: in_chf).merge("currency" => "chf"))
    import!
    assert_equal "CHF", @item.tricount_accounts.sole.currency

    @provider.stubs(:registry).returns(tricount_registry.merge("currency" => "XXX"))
    import!
    assert_equal "CHF", @item.tricount_accounts.sole.currency
  end

  # A first read without them would set the tricount up in EUR whatever its
  # currency, or under a key the next complete read doesn't match.
  test "a first read without a currency or the tricount's uuid sets nothing up" do
    @provider.stubs(:synchronize!)
    {
      "currency_missing" => tricount_registry.except("currency"),
      "currency_missing (unknown)" => tricount_registry.merge("currency" => "XXX"),
      "identifier_missing" => tricount_registry.except("uuid")
    }.each do |label, registry|
      @provider.stubs(:registry).returns(registry)
      sync = Sync.create!(syncable: @item)
      TricountItem::Importer.new(@item, tricount_provider: @provider, sync: sync).import

      assert_empty @item.tricount_accounts.reload, label
      assert_equal [ I18n.t("tricount_items.sync.errors.#{label.split.first}") ], sync.reload.sync_stats["errors"].map { |error| error["message"] }, label
    end
  end

  test "a later import keeps the chosen member and updates the balance" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry)
    import!
    @item.tricount_accounts.sole.assign_member!(ME)

    @provider.stubs(:registry).returns(tricount_registry(entries: tricount_entries.first(2)))
    import!

    assert_equal [ ME, BigDecimal("65") ], @item.tricount_accounts.sole.values_at(:member_uuid, :current_balance)
  end

  test "an unlinked tricount whose link was removed is dropped" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry)
    import!
    @item.update!(sharing_tokens: "tOtherToken9")

    @provider.stubs(:registry).with("tOtherToken9").returns(tricount_registry.merge("uuid" => "other-uuid"))
    import!

    assert_equal [ "other-uuid" ], @item.tricount_accounts.pluck(:tricount_account_id)
  end

  # Tricount answering without the tricount is a failed read: the link is
  # still followed, so its account stays, and the read counts as an error.
  test "a followed tricount that comes back empty is an error and keeps its account" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry)
    import!

    @provider.stubs(:registry).returns(nil)
    sync = Sync.create!(syncable: @item)
    TricountItem::Importer.new(@item, tricount_provider: @provider, sync: sync).import

    assert_equal [ REGISTRY_UUID ], @item.tricount_accounts.pluck(:tricount_account_id)
    assert_equal [ I18n.t("tricount_items.sync.errors.tricount_missing") ], sync.reload.sync_stats["errors"].map { |error| error["message"] }
  end

  # A registry without its entry list says nothing about the entries; taken as
  # empty it would remove every imported transaction.
  test "a tricount returned without its entries is an error and keeps what was imported" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry)
    import!

    @provider.stubs(:registry).returns(tricount_registry.except("all_registry_entry"))
    sync = Sync.create!(syncable: @item)
    TricountItem::Importer.new(@item, tricount_provider: @provider, sync: sync).import

    assert_equal 5, @item.tricount_accounts.sole.raw_transactions_payload.size
    assert_equal [ I18n.t("tricount_items.sync.errors.entries_missing") ], sync.reload.sync_stats["errors"].map { |error| error["message"] }
  end

  # Each would replace what was imported with less: no entries, no members
  # (dropping the account's member), or an expense without its shares (which
  # would count in full for its payer).
  test "a partial tricount is an error and keeps what was imported" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry)
    import!
    @item.tricount_accounts.sole.assign_member!(ME)

    # An active entry missing what the ledger needs would drop out of the
    # snapshot and take its transactions with it.
    without = ->(*path) { tricount_entries.map(&:deep_dup).tap { |entries| path.size == 1 ? entries.first["RegistryEntry"].delete(path.first) : entries.first["RegistryEntry"].dig(*path[0..-2]).delete(path.last) } }
    {
      "entries_missing" => tricount_registry.merge("all_registry_entry" => nil),
      "members_missing" => tricount_registry.except("memberships"),
      "entries_incomplete" => tricount_registry(entries: without.call("allocations")),
      "entries_incomplete (uuid)" => tricount_registry(entries: without.call("uuid")),
      "entries_incomplete (date)" => tricount_registry(entries: without.call("date")),
      "entries_incomplete (amount)" => tricount_registry(entries: without.call("amount", "value")),
      "entries_incomplete (not an object)" => tricount_registry(entries: tricount_entries + [ nil ]),
      "entries_incomplete (no payer)" => tricount_registry(entries: without.call("membership_owned")),
      "entries_incomplete (unknown payer)" => tricount_registry(entries: tricount_entries.map(&:deep_dup).tap { |entries| entries.first["RegistryEntry"]["membership_owned"] = { "RegistryMembershipNonUser" => { "uuid" => "nobody" } } }),
      "members_incomplete" => tricount_registry.merge("memberships" => tricount_registry["memberships"] + [ { "RegistryMembershipNonUser" => {} } ]),
      "entries_incomplete (unreadable date)" => tricount_registry(entries: with_first_entry { |entry| entry["date"] = "not-a-date" }),
      "entries_incomplete (empty share)" => tricount_registry(entries: with_first_entry { |entry| entry["allocations"] = [ {} ] }),
      "entries_incomplete (share not an object)" => tricount_registry(entries: with_first_entry { |entry| entry["allocations"] << "share" }),
      "entries_incomplete (share without amount)" => tricount_registry(entries: with_first_entry { |entry| entry["allocations"].first.delete("amount") }),
      "entries_incomplete (share of a stranger)" => tricount_registry(entries: with_first_entry { |entry| entry["allocations"].first["membership"] = { "RegistryMembershipNonUser" => { "uuid" => "nobody" } } }),
      "entries_incomplete (shares short of the total)" => tricount_registry(entries: with_first_entry { |entry| entry["allocations"].pop }),
      "foreign_currency_entry" => tricount_registry(entries: with_first_entry { |entry| entry["amount"]["currency"] = "USD" }),
      "foreign_currency_entry (not a currency)" => tricount_registry(entries: with_first_entry { |entry| entry["amount"]["currency"] = "XXX" }),
      "entries_incomplete (no type)" => tricount_registry(entries: without.call("type_transaction")),
      "entries_incomplete (entry listed twice)" => tricount_registry(entries: tricount_entries + [ tricount_entries.first.deep_dup ]),
      "entries_incomplete (ratio share without its ratio)" => tricount_registry(entries: with_first_entry { |entry| entry["allocations"].each { |allocation| allocation["type"] = "RATIO"; allocation["share_ratio"] = 1 }.first.delete("share_ratio") }),
      "identifier_missing" => tricount_registry.except("uuid"),
      "currency_missing" => tricount_registry.except("currency")
    }.each do |label, registry|
      problem = label.split.first
      @provider.stubs(:registry).returns(registry)
      sync = Sync.create!(syncable: @item)
      TricountItem::Importer.new(@item, tricount_provider: @provider, sync: sync).import

      tricount_account = @item.tricount_accounts.sole
      assert_equal [ 5, ME, BigDecimal("-20") ], [ tricount_account.raw_transactions_payload.size, tricount_account.member_uuid, tricount_account.current_balance ], label
      assert_equal [ I18n.t("tricount_items.sync.errors.#{problem}") ], sync.reload.sync_stats["errors"].map { |error| error["message"] }
    end
  end

  # Shares split by ratio are stored rounded to the cent and can miss the
  # entry's total by a cent each.
  test "shares a cent off the total per share still import" do
    @provider.stubs(:synchronize!)
    rounded = tricount_entry(uuid: "e6", payer: ME, amount: "-10.00", allocations: { ME => "-3.33", SAM => "-3.33", KIM => "-3.33" })
    rounded["RegistryEntry"]["allocations"].each { |allocation| allocation["type"] = "RATIO"; allocation["share_ratio"] = 1 }
    @provider.stubs(:registry).returns(tricount_registry(entries: tricount_entries + [ rounded ]))
    sync = Sync.create!(syncable: @item)
    TricountItem::Importer.new(@item, tricount_provider: @provider, sync: sync).import

    assert_equal 6, @item.tricount_accounts.sole.raw_transactions_payload.size
    assert_nil sync.reload.sync_stats["errors"]
  end

  test "a tricount with no expenses is imported as empty" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry(entries: []))
    sync = Sync.create!(syncable: @item)
    TricountItem::Importer.new(@item, tricount_provider: @provider, sync: sync).import

    assert_equal [], @item.tricount_accounts.sole.raw_transactions_payload
    assert_nil sync.reload.sync_stats["errors"]
  end

  test "a refused session marks the connection for attention" do
    @provider.stubs(:synchronize!).raises(Provider::Tricount::AuthenticationError.new("refused"))

    assert_raises(Provider::Tricount::AuthenticationError) { import! }
    assert @item.reload.requires_update?
  end

  private
    # The fixture's entries with the first one's fields changed.
    def with_first_entry
      tricount_entries.map(&:deep_dup).tap { |entries| yield entries.first["RegistryEntry"] }
    end
end
