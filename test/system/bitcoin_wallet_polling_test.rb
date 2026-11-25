require "application_system_test_case"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletPollingTest < ApplicationSystemTestCase
  include BitcoinWalletTestHelper

  test "a delayed discovery response prevents overlapping polls and polling still reaches the preview" do
    user = users(:family_admin)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    account = accounts(:crypto)
    wallet = build_bitcoin_wallet(account: account, status: :discovering)
    manual_bitcoin_source(wallet)
    sync = wallet.sync_later
    sign_in user

    visit account_bitcoin_wallet_path(account)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      let walletPolls = 0;
      window.fetch = async (url, options) => {
        if (!options?.headers?.["Turbo-Frame"]?.startsWith("status_")) {
          return originalFetch(url, options);
        }

        const attempt = ++walletPolls;
        document.documentElement.dataset.walletPolls = attempt;
        const response = await originalFetch(url, options);
        if (attempt !== 1) return response;

        const html = await response.text();
        return new Promise((resolve) => {
          window.releaseWalletPoll = () => resolve(new Response(html));
          document.documentElement.dataset.walletPollHeld = "true";
        });
      };
    JS
    assert_text I18n.t("bitcoin_wallets.discovering_title")
    find("summary", text: /#{Regexp.escape(I18n.t("bitcoin_wallets.details"))}/i).click
    assert_text I18n.t("bitcoin_wallets.address_count", count: 0)
    assert_selector "html[data-wallet-poll-held='true']"

    wallet.bitcoin_wallet_addresses.create!(family: wallet.family, address: RECEIVE, used: true)
    wallet.update!(status: :preview, balance_sats: 20_000_000, last_synced_at: Time.current)
    sync.update!(status: :completed)

    # Keep the old response pending through the next polling tick.
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const frame = document.querySelector("turbo-frame[data-polling-url-value]");
      const interval = Number(frame.dataset.pollingIntervalValue || 3000);
      setTimeout(() => done(true), interval + 100);
    JS
    assert_equal "1", page.evaluate_script("document.documentElement.dataset.walletPolls")
    page.execute_script("window.releaseWalletPoll()")

    assert_text I18n.t("bitcoin_wallets.start_tracking")
    within "turbo-frame[id^='addresses_']" do
      assert_text I18n.t("bitcoin_wallets.address_count", count: 1)
      assert_selector "li", exact_text: RECEIVE
    end
  end
end
