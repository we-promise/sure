# frozen_string_literal: true

require "test_helper"

class BankSyncStatusComponentTest < ViewComponent::TestCase
  test "healthy snapshot status stays compact while retaining its timestamp" do
    snapshot_at = 2.hours.ago
    item = OpenStruct.new(portfolio_snapshot_at: snapshot_at, syncing?: false)
    presenter = BankSyncStatusPresenter.new(item: item, provider_key: :fineco, background_sync_enabled: false)

    render_inline BankSyncStatusComponent.new(presenter: presenter)

    assert_text "Latest snapshot saved"
    assert_text "Last successful data snapshot"
    assert_selector "div[role='status']"
    assert_no_selector "div[role='status'][class~='bg-success/10']"
  end

  test "rate limited snapshot status uses the warning alert and keeps the prior timestamp" do
    item = OpenStruct.new(
      syncing?: false,
      requires_update?: false,
      session_configured?: true,
      last_sync_error_code: "rate_limited",
      sync_rate_limited?: true,
      sync_cooldown?: true,
      sync_eligible_at: 30.minutes.from_now,
      snapshot_at: 2.hours.ago
    )
    presenter = BankSyncStatusPresenter.new(item: item, provider_key: :ca_auto_bank, background_sync_enabled: false)

    render_inline BankSyncStatusComponent.new(presenter: presenter)

    assert_selector "div[role='status'][class~='bg-warning/10']"
    assert_text "Requests temporarily limited"
    assert_text "Previously saved data remains available"
    assert_text "Last successful data snapshot"
  end
end
