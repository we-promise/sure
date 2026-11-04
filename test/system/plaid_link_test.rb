require "application_system_test_case"

# Plaid Link can't run here, so each test puts a stand-in on window.Plaid that
# finishes at once, as Link's onSuccess would, and the real Stimulus controller
# takes it from there.
class PlaidLinkTest < ApplicationSystemTestCase
  setup do
    provider = mock
    provider.stubs(:get_link_token).returns(OpenStruct.new(link_token: "link-sandbox-test"))
    Provider::Registry.stubs(:plaid_provider_for_region).returns(provider)

    sign_in users(:family_admin)
  end

  test "shows the duplicate warning the server sends" do
    families(:dylan_family).plaid_items.create!(
      name: "Example Bank",
      plaid_id: "item_system_test",
      access_token: "access-system-test",
      plaid_region: :us,
      institution_id: "ins_example",
      owner: users(:family_admin)
    )

    finish_link

    assert_selector "dialog", text: I18n.t("plaid_items.duplicate_warning.title", count: 1)
    assert_no_selector "#notification-tray", text: create_failed_message
  end

  # Link has closed by the time the request fails, so nothing else on the page
  # changes to say so.
  test "says so when the request to add the connection fails" do
    answer_create_with "Promise.reject(new TypeError('Failed to fetch'))"

    finish_link

    assert_selector "#notification-tray", text: create_failed_message
  end

  test "says so when the server can't add the connection" do
    answer_create_with "Promise.resolve(new Response('', { status: 500 }))"

    finish_link

    assert_selector "#notification-tray", text: create_failed_message
  end

  private
    def create_failed_message
      I18n.t("plaid_items.auto_link_opener.create_failed")
    end

    # Opens Link the way the account-type screen does, into the modal frame.
    def finish_link
      execute_script(<<~JS)
        // The controller sends the page's CSRF token, and the test environment, with
        // forgery protection off, renders no token to send.
        if (!document.querySelector('meta[name="csrf-token"]')) {
          document.head.insertAdjacentHTML("beforeend", '<meta name="csrf-token" content="system-test">');
        }

        window.Plaid = {
          create: (config) => ({
            open: () => config.onSuccess("public-sandbox-test", {
              institution: { name: "Example Bank", institution_id: "ins_example" },
              accounts: []
            }),
            destroy: () => {}
          })
        };

        const link = document.createElement("a");
        link.id = "open-plaid-link";
        link.href = "/plaid_items/new?region=us";
        link.dataset.turboFrame = "modal";
        link.textContent = "Open Plaid Link";
        // The app's layout fills the viewport, so a link merely appended to the body
        // is scrolled out of reach.
        link.style.cssText = "position: fixed; top: 0; left: 0; z-index: 100;";
        document.body.append(link);
      JS

      find("#open-plaid-link").click
    end

    # Replaces the browser's answer to the request that adds the connection, and only
    # that one, since Turbo fetches the modal frame through the same function.
    def answer_create_with(response)
      execute_script(<<~JS)
        const fetchOriginal = window.fetch;
        window.fetch = (url, options) => url === "/plaid_items" ? #{response} : fetchOriginal(url, options);
      JS
    end
end
