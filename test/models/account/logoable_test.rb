require "test_helper"

class Account::LogoableTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "logo.png", content_type: "image/png")
    ActiveStorage.stubs(:urls_expire_in).returns(7.days)
  end

  test "a stored logo's URL stays the same through the day, so the browser can cache it" do
    travel_to Time.zone.local(2026, 11, 10, 9) do
      morning = Account.find(@account.id).stored_logo_url

      travel 8.hours
      assert_equal morning, Account.find(@account.id).stored_logo_url

      travel 1.day
      assert_not_equal morning, Account.find(@account.id).stored_logo_url, "a new day gives a new expiry"
    end
  end

  test "a new logo gets a new URL the same day, so the browser doesn't keep showing the old one" do
    before = Account.find(@account.id).stored_logo_url

    @account.logo.attach(io: file_fixture("profile_image.png").open, filename: "logo.png", content_type: "image/png")

    assert_not_equal before, Account.find(@account.id).stored_logo_url
  end

  test "a stored logo's URL still finds its logo and expires no sooner than configured" do
    travel_to Time.zone.local(2026, 11, 10, 9) do
      signed_id = Account.find(@account.id).stored_logo_url.split("/")[-2]

      travel 7.days - 1.minute
      assert_equal @account.logo.blob, ActiveStorage::Blob.find_signed(signed_id)

      travel 2.days
      assert_nil ActiveStorage::Blob.find_signed(signed_id), "it expires a day later at most"
    end
  end
end
