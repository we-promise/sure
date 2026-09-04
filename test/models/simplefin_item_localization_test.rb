require "test_helper"

class SimplefinItemLocalizationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @simplefin_item = create_simplefin_item
  end

  test "sync summaries are localized with account-aware pluralization" do
    sync = create_sync(total: 0, linked: 0, unlinked: 0)

    assert_localized_summary sync, de: "Keine Konten gefunden", en: "No accounts found"

    sync.update!(sync_stats: sync_stats(total: 1, linked: 1, unlinked: 0))
    assert_localized_summary sync, de: "1 Konto synchronisiert", en: "1 account synced"

    sync.update!(sync_stats: sync_stats(total: 2, linked: 2, unlinked: 0))
    assert_localized_summary sync, de: "2 Konten synchronisiert", en: "2 accounts synced"

    sync.update!(sync_stats: sync_stats(total: 2, linked: 1, unlinked: 1))
    assert_localized_summary sync, de: "1 synchronisiert, 1 muss eingerichtet werden", en: "1 synced, 1 need setup"

    sync.update!(sync_stats: sync_stats(total: 3, linked: 1, unlinked: 2))
    assert_localized_summary sync, de: "1 synchronisiert, 2 müssen eingerichtet werden", en: "1 synced, 2 need setup"
  end

  test "sync summaries fall back to linked and unlinked account counts" do
    all_synced_item = create_simplefin_item
    Sync.create!(syncable: all_synced_item, status: "completed", completed_at: Time.current)
    all_synced_provider_account = create_simplefin_account(all_synced_item, account_id: "all-synced", org_data: {})
    create_linked_account(all_synced_provider_account, name: "All-synced account")

    assert_localized_item_summary all_synced_item, de: "1 Konto synchronisiert", en: "1 account synced"

    partial_item = create_simplefin_item
    Sync.create!(syncable: partial_item, status: "completed", completed_at: Time.current)
    linked_provider_account = create_simplefin_account(partial_item, account_id: "linked-fallback", org_data: {})
    create_linked_account(linked_provider_account, name: "Linked fallback account")
    create_simplefin_account(partial_item, account_id: "unlinked-fallback", org_data: {})

    assert_localized_item_summary partial_item,
                                  de: "1 synchronisiert, 1 muss eingerichtet werden",
                                  en: "1 synced, 1 need setup"
  end

  test "institution summaries localize fallbacks and preserve provider names" do
    assert_localized_institution_summary @simplefin_item,
                                         de: "Keine Institute verbunden",
                                         en: "No institutions connected"

    named_item = create_simplefin_item
    create_simplefin_account(named_item, account_id: "named", org_data: { "name" => "Fjord Bank" })
    assert_localized_institution_summary named_item, de: "Fjord Bank", en: "Fjord Bank"

    unnamed_item = create_simplefin_item
    create_simplefin_account(unnamed_item, account_id: "unnamed", org_data: { "id" => "provider-1" })
    assert_localized_institution_summary unnamed_item, de: "1 Institut", en: "1 institution"

    multiple_item = create_simplefin_item
    create_simplefin_account(multiple_item, account_id: "first", org_data: { "name" => "Fjord Bank" })
    create_simplefin_account(multiple_item, account_id: "second", org_data: { "name" => "Harbor Credit" })
    assert_localized_institution_summary multiple_item, de: "2 Institute", en: "2 institutions"
  end

  test "daily refresh limit message is localized without changing the provider error" do
    provider_error = "SimpleFin rate limit: data refreshes at most once every 24 hours."
    sync = Sync.create!(
      syncable: @simplefin_item,
      status: "failed",
      failed_at: Time.current,
      error: provider_error
    )

    assert_equal "Du hast das tägliche Aktualisierungslimit von SimpleFIN erreicht. Versuch es erneut, sobald die SimpleFIN Bridge die Daten aktualisiert hat (das kann bis zu 24 Stunden dauern).",
                 I18n.with_locale(:de) { @simplefin_item.rate_limited_message }
    assert_equal "You've hit SimpleFIN's daily refresh limit. Please try again after the bridge refreshes (up to 24 hours).",
                 I18n.with_locale(:en) { @simplefin_item.rate_limited_message }
    assert_equal provider_error, sync.reload.error
  end

  test "stale successful sync message is localized" do
    travel_to Time.zone.local(2026, 9, 2, 12) do
      Sync.create!(
        syncable: @simplefin_item,
        status: "completed",
        completed_at: 5.days.ago
      )

      assert_equal "Die letzte erfolgreiche Synchronisierung war vor 5 Tagen. Deine SimpleFIN-Verbindung braucht möglicherweise Aufmerksamkeit.",
                   I18n.with_locale(:de) { @simplefin_item.stale_sync_status[:message] }
      assert_equal "Last successful sync was 5 days ago. Your SimpleFIN connection may need attention.",
                   I18n.with_locale(:en) { @simplefin_item.stale_sync_status[:message] }
    end
  end

  test "stale transaction message is localized" do
    travel_to Time.zone.local(2026, 9, 2, 12) do
      Sync.create!(
        syncable: @simplefin_item,
        status: "completed",
        completed_at: 1.day.ago
      )
      account = Account.create!(
        family: @family,
        name: "Everyday account",
        accountable: Depository.new(subtype: "checking"),
        balance: 100,
        currency: "USD"
      )
      simplefin_account = create_simplefin_account(@simplefin_item, account_id: "linked", org_data: { "name" => "Fjord Bank" })
      account.update!(simplefin_account: simplefin_account)
      create_transaction(account: account, name: "Invented purchase", date: 20.days.ago.to_date)

      assert_equal "Seit 20 Tagen gibt es keine neuen Transaktionen. Prüfe in deinem SimpleFIN-Dashboard, ob deine Bankverbindungen aktiv sind.",
                   I18n.with_locale(:de) { @simplefin_item.reload.stale_sync_status[:message] }
      assert_equal "No new transactions in 20 days. Check your SimpleFIN dashboard to ensure your bank connections are active.",
                   I18n.with_locale(:en) { @simplefin_item.reload.stale_sync_status[:message] }
    end
  end

  test "German summary translations exist without fallback" do
    assert_equal "Keine Konten gefunden",
                 I18n.t("simplefin_items.sync_status.no_accounts", locale: :de, fallback: false, default: nil)
    assert_equal "2 Konten synchronisiert",
                 I18n.t("simplefin_items.sync_status.synced", locale: :de, fallback: false, default: nil, count: 2)
    assert_equal "1 synchronisiert, 2 müssen eingerichtet werden",
                 I18n.t("simplefin_items.sync_status.partial_setup", locale: :de, fallback: false, default: nil,
                        count: 2, linked: 1, unlinked: 2)
    assert_equal "2 Institute",
                 I18n.t("simplefin_items.institution_summary.count", locale: :de, fallback: false, default: nil, count: 2)
    assert I18n.t("simplefin_items.rate_limited.daily_refresh", locale: :de, fallback: false, default: nil).present?
    assert I18n.t("simplefin_items.stale_sync.last_successful", locale: :de, fallback: false, default: nil, count: 5).present?
    assert I18n.t("simplefin_items.stale_sync.no_transactions", locale: :de, fallback: false, default: nil, count: 20).present?
  end

  private
    def create_simplefin_item
      SimplefinItem.create!(
        family: @family,
        name: "Invented SimpleFIN connection",
        access_url: "synthetic-simplefin-access"
      )
    end

    def create_simplefin_account(item, account_id:, org_data:)
      item.simplefin_accounts.create!(
        name: "Invented provider account",
        account_id: account_id,
        currency: "USD",
        account_type: "checking",
        current_balance: 100,
        org_data: org_data
      )
    end

    def create_sync(total:, linked:, unlinked:)
      Sync.create!(
        syncable: @simplefin_item,
        status: "completed",
        completed_at: Time.current,
        sync_stats: sync_stats(total: total, linked: linked, unlinked: unlinked)
      )
    end

    def create_linked_account(simplefin_account, name:)
      Account.create!(
        family: @family,
        name: name,
        accountable: Depository.new(subtype: "checking"),
        balance: 100,
        currency: "USD",
        simplefin_account: simplefin_account
      )
    end

    def sync_stats(total:, linked:, unlinked:)
      {
        "total_accounts" => total,
        "linked_accounts" => linked,
        "unlinked_accounts" => unlinked
      }
    end

    def assert_localized_summary(sync, de:, en:)
      sync.reload
      assert_equal de, I18n.with_locale(:de) { @simplefin_item.sync_status_summary }
      assert_equal en, I18n.with_locale(:en) { @simplefin_item.sync_status_summary }
    end

    def assert_localized_item_summary(item, de:, en:)
      assert_equal de, I18n.with_locale(:de) { item.sync_status_summary }
      assert_equal en, I18n.with_locale(:en) { item.sync_status_summary }
    end

    def assert_localized_institution_summary(item, de:, en:)
      assert_equal de, I18n.with_locale(:de) { item.institution_summary }
      assert_equal en, I18n.with_locale(:en) { item.institution_summary }
    end
end
