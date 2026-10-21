require "test_helper"

class IdentifierMaskTest < ActiveSupport::TestCase
  test "keeps only the last 4 characters behind the marker" do
    assert_equal "•••7890", IdentifierMask.last4("DE89370400440532017890")
    assert_equal "•••2345", IdentifierMask.last4(12345)
  end

  test "returns nil for blank input" do
    assert_nil IdentifierMask.last4(nil)
    assert_nil IdentifierMask.last4("")
    assert_nil IdentifierMask.last4("   ", strip_whitespace: true)
  end

  # Fine for an account number, but the reason this must never mask secrets.
  test "shows a value of 4 characters or fewer in full" do
    assert_equal "•••123", IdentifierMask.last4("123")
    assert_equal "•••1234", IdentifierMask.last4("1234")
  end

  test "hide_short returns nil for values under 4 characters" do
    assert_nil IdentifierMask.last4("123", hide_short: true)
    assert_equal "•••1234", IdentifierMask.last4("1234", hide_short: true)
  end

  test "strip_whitespace ignores grouping spaces" do
    assert_equal "•••7890", IdentifierMask.last4("DE89 3704 0044 0532 0178 90", strip_whitespace: true)
    assert_equal "•••8 90", IdentifierMask.last4("DE89 3704 0044 0532 0178 90")
  end

  test "accepts a custom prefix" do
    assert_equal "****1234", IdentifierMask.last4("55551234", prefix: "****")
  end

  test "last4_chars returns the characters without a marker" do
    assert_equal "1234", IdentifierMask.last4_chars("5555 1234", strip_whitespace: true)
    assert_nil IdentifierMask.last4_chars("12", hide_short: true)
  end

  test "strip_dashes ignores dash separators" do
    assert_equal "•••2300", IdentifierMask.last4("12-3456-7890123-00", strip_dashes: true)
  end

  test "mask_identifiers masks values under identifier keys only" do
    masked = IdentifierMask.mask_identifiers({
      "counter_iban" => "UA213223130000026007233566001", # pipelock:ignore IBAN
      "counterAccountName" => "Jane Doe",
      "details" => { "routingNumber" => "021000021", "account_number_last_4" => "6001" },
      "other_account" => [ "12-3456-7890123-00" ]
    })

    assert_equal "•••6001", masked["counter_iban"]
    assert_equal "Jane Doe", masked["counterAccountName"]
    assert_equal({ "routingNumber" => "•••0021", "account_number_last_4" => "6001" }, masked["details"])
    assert_equal [ "•••2300" ], masked["other_account"]
  end

  test "mask_identifiers leaves descriptive fields under an identifier key alone" do
    masked = IdentifierMask.mask_identifiers({
      "card_number" => { "last4" => "1234", "brand" => "visa" },
      "counter_account" => { "name" => "Jane Doe", "number" => "1234567890/2010", "iban" => "CZ6508000000192000145399" } # pipelock:ignore IBAN
    })

    assert_equal "visa", masked["card_number"]["brand"]
    assert_equal "Jane Doe", masked["counter_account"]["name"]
    assert_equal "•••7890/2010", masked["counter_account"]["number"]
    assert_equal "•••5399", masked["counter_account"]["iban"]
  end

  test "mask_identifiers still masks numbers under other or deeper keys of an identifier object" do
    masked = IdentifierMask.mask_identifiers({
      "counter_account" => { "accountId" => "12-3456-7890123-00" },
      "iban" => { "full" => "DE89370400440532013000" }, # pipelock:ignore IBAN
      "card_number" => { "details" => { "number" => "4111111111111111", "brand" => "visa" } },
      "other_account" => [ { "name" => "Jane Doe", "number" => "1234567890" } ]
    })

    assert_equal "•••2300", masked["counter_account"]["accountId"]
    assert_equal "•••3000", masked["iban"]["full"]
    assert_equal "•••1111", masked["card_number"]["details"]["number"]
    assert_equal "visa", masked["card_number"]["details"]["brand"]
    assert_equal [ { "name" => "Jane Doe", "number" => "•••7890" } ], masked["other_account"]
  end

  test "mask_identifier ignores grouping spaces" do
    assert_equal "•••7890", IdentifierMask.mask_identifier("DE89 3704 0044 0532 0178 90") # pipelock:ignore IBAN
  end

  test "mask_identifier keeps a Czech bank code" do
    assert_equal "•••7890/2010", IdentifierMask.mask_identifier("1234567890/2010")
  end
end
