require "test_helper"

class Money::CurrencyTest < ActiveSupport::TestCase
  setup do
    @currency = Money::Currency.new(:usd)
  end

  test "has many currencies" do
    assert_operator Money::Currency.all.count, :>, 100
  end

  test "can test equality of currencies" do
    assert_equal Money::Currency.new(:usd), Money::Currency.new(:usd)
    assert_not_equal Money::Currency.new(:usd), Money::Currency.new(:eur)
  end

  test "can get metadata about a currency" do
    assert_equal "USD", @currency.iso_code
    assert_equal "United States Dollar", @currency.name
    assert_equal "$", @currency.symbol
    assert_equal 1, @currency.priority
    assert_equal "Cent", @currency.minor_unit
    assert_equal 100, @currency.minor_unit_conversion
    assert_equal 1, @currency.smallest_denomination
    assert_equal ".", @currency.separator
    assert_equal ",", @currency.delimiter
    assert_equal "%u%n", @currency.default_format
    assert_equal 2, @currency.default_precision
  end

  test "step returns the smallest value of the currency" do
    assert_equal 0.01, @currency.step
  end

  test "ethereum uses wei native scale" do
    eth = Money::Currency.new(:eth)
    assert_equal "Ethereum", eth.name
    assert_equal "ETH", eth.iso_code
    assert_equal "Ξ", eth.symbol
    assert_equal "Wei", eth.minor_unit
    assert_equal 1000000000000000000, eth.minor_unit_conversion
    assert_equal 8, eth.default_precision
  end

  test "ethereum step represents display precision" do
    eth = Money::Currency.new(:eth)
    assert_equal 0.00000001, eth.step
  end

  test "ethereum conversion formula: step = 10^-default_precision" do
    eth = Money::Currency.new(:eth)
    expected_step = 1.0 / (10 ** eth.default_precision)
    assert_equal expected_step, eth.step
  end

  # A duplicate YAML key in one of these currencies' blocks silently
  # resolves to its last value rather than raising, so a copy-paste mistake
  # across this many similar blocks would carry no parse error to catch it.
  # Each currency's iso_code/symbol/precision/conversion must come out
  # exactly as its own entry defines, independent of every other one.
  #
  # minor_unit_conversion is each asset's own real native-chain scale (the
  # same convention already used for btc/satoshi and eth/wei above), not a
  # blanket copy of btc's -- money_to_minor_units and the API serializers
  # (balance_cents, amount_cents, etc.) multiply by this directly, so the
  # wrong factor here misreports a real balance by orders of magnitude.
  # baby/boden/nos are left at the 8-decimal placeholder: multiple tokens
  # share each of these tickers across different chains, and which contract
  # Coinbase's own data refers to couldn't be confirmed from public sources.
  test "the 32 added crypto currencies use their correct precision and conversion" do
    expected_conversion = {
      "ada" => 1_000_000,             # lovelace
      "sol" => 1_000_000_000,         # lamport
      "zec" => 100_000_000,           # zatoshi
      "storj" => 100_000_000,         # confirmed 8-decimal ERC-20, not the 18-decimal default
      "baby" => 100_000_000,          # unverified -- see note above
      "boden" => 100_000_000,         # unverified -- see note above
      "nos" => 100_000_000            # unverified -- see note above
    }
    default_conversion = 1_000_000_000_000_000_000 # wei -- the 18-decimal ERC-20/EVM default

    %w[
      ada amp avax baby bal band bat boden bond cgld clv comp enj fet fil
      forth grt knc nkn nos nu ogn pol ren skl sky snx sol storj sushi uni zec
    ].each do |code|
      currency = Money::Currency.new(code)
      assert_equal code.upcase, currency.iso_code, "#{code}: iso_code"
      assert_equal code.upcase, currency.symbol, "#{code}: symbol"
      assert_equal 8, currency.default_precision, "#{code}: default_precision"
      assert_equal expected_conversion.fetch(code, default_conversion), currency.minor_unit_conversion, "#{code}: minor_unit_conversion"
    end
  end
end
