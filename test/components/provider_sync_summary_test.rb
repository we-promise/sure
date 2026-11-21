require "test_helper"

class ProviderSyncSummaryTest < ViewComponent::TestCase
  setup do
    @provider = Struct.new(:last_synced_at).new(nil)
  end

  test "Russian rate limit without a timestamp is a complete sentence" do
    I18n.with_locale(:ru) do
      render_inline(ProviderSyncSummary.new(stats: { "rate_limited" => true }, provider_item: @provider))

      assert_selector ".text-warning", text: "Недавно достигнут лимит запросов.", visible: :all
      assert_no_text "недавно назад"
    end
  end

  test "Russian rate limit with a timestamp keeps the elapsed-time suffix" do
    travel_to Time.zone.local(2026, 10, 26, 12) do
      I18n.with_locale(:ru) do
        render_inline(ProviderSyncSummary.new(
          stats: { "rate_limited_at" => 5.minutes.ago.iso8601 }, provider_item: @provider))

        assert_selector ".text-warning", text: /Достигнут лимит запросов .+ назад\./, visible: :all
      end
    end
  end

  test "a locale without the new sentence keeps its existing translated fallback" do
    I18n.with_locale(:de) do
      expected = I18n.t("provider_sync_summary.health.rate_limited",
        time_ago: I18n.t("provider_sync_summary.health.recently"))
      render_inline(ProviderSyncSummary.new(stats: { "rate_limited" => true }, provider_item: @provider))

      assert_selector ".text-warning", text: expected, visible: :all
    end
  end
end
