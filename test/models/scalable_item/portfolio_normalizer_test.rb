require "test_helper"

class ScalableItem::PortfolioNormalizerTest < ActiveSupport::TestCase
  test "uses brokerage cash exactly once and includes all discovered broker portfolios" do
    snapshot = normalize_snapshot(
      ids: %w[broker-portfolio-a broker-portfolio-b],
      cash_balance: "50",
      cash_available_to_invest: "500",
      valuation_includes_cash: true
    )

    assert_equal %w[broker-portfolio-a broker-portfolio-b], snapshot.accounts.map(&:uid)
    assert_equal BigDecimal("50"), snapshot.accounts.first.cash_balance
    assert_equal BigDecimal("150"), snapshot.accounts.first.current_balance
    assert_equal "verified-person", snapshot.person_identity
    assert_equal "broker-account", snapshot.account_id
    assert_equal snapshot.fetched_at, snapshot.accounts.first.observed_at
    assert_equal snapshot.accounts.first.raw_metadata.fetch("valuation_timestamp"),
      snapshot.accounts.first.valuation_timestamp.utc.iso8601
  end

  test "accepts small positive or negative cash when rounding matches both overview interpretations" do
    positive = normalize_snapshot(positions: [], cash_balance: "0.01", valuation_includes_cash: false)
    negative = normalize_snapshot(positions: [], cash_balance: "-0.01", valuation_includes_cash: false)

    assert_equal BigDecimal("0.01"), positive.accounts.sole.current_balance
    assert_equal BigDecimal("-0.01"), negative.accounts.sole.current_balance
  end

  test "accepts the overview whether its valuation includes cash or only securities" do
    with_cash = normalize_snapshot(cash_balance: "50", valuation_includes_cash: true)
    securities_only = normalize_snapshot(cash_balance: "50", valuation_includes_cash: false)

    assert_equal BigDecimal("150"), with_cash.accounts.sole.current_balance
    assert_equal BigDecimal("150"), securities_only.accounts.sole.current_balance
  end

  test "rejects a noncoherent valuation instead of importing a partial snapshot" do
    error = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(cash_balance: "50", overview_valuation: "149.50")
    end

    assert_equal "invalid_snapshot", error.code
  end

  test "rejects non-EUR values and nonzero crypto rather than guessing conversions" do
    currency_error = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(position_currency: "USD")
    end
    crypto_error = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(crypto_valuation: "1")
    end
    margin_error = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(loaned: "10")
    end

    assert_equal "unsupported_account", currency_error.code
    assert_equal "unsupported_account", crypto_error.code
    assert_equal "unsupported_account", margin_error.code
  end

  test "rejects duplicate broker portfolio IDs and duplicate ISIN positions" do
    duplicate_portfolios = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(ids: %w[broker-portfolio-a broker-portfolio-a])
    end
    duplicate_positions = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(positions: [ position, position ])
    end

    assert_equal "invalid_snapshot", duplicate_portfolios.code
    assert_equal "invalid_snapshot", duplicate_positions.code
  end

  test "requires inventory and response account and portfolio identities to match discovery" do
    missing_inventory = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(missing_inventory: true)
    end
    wrong_account = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(response_account_id: "another-account")
    end
    wrong_portfolio = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(response_portfolio_id: "another-portfolio")
    end

    assert_equal "invalid_snapshot", missing_inventory.code
    assert_equal "invalid_snapshot", wrong_account.code
    assert_equal "invalid_snapshot", wrong_portfolio.code
  end

  test "rejects stale or future-skewed valuation timestamps" do
    stale = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(observed_at: 73.hours.ago)
    end
    future = assert_raises(Provider::Scalable::Error) do
      normalize_snapshot(observed_at: 6.minutes.from_now)
    end

    assert_equal "stale_snapshot", stale.code
    assert_equal "invalid_snapshot", future.code
  end

  private

    def normalize_snapshot(ids: [ "broker-portfolio" ], positions: [ position ], cash_balance: "50",
      cash_available_to_invest: "500", valuation_includes_cash: true, overview_valuation: nil,
      position_currency: "EUR", crypto_valuation: "0", loaned: "0", observed_at: Time.current,
      missing_inventory: false, response_account_id: "broker-account", response_portfolio_id: nil)
      now = Time.current
      discovery = {
        "account" => {
          "id" => "broker-account",
          "brokerPortfolios" => ids.map { |id| { "id" => id } }
        }
      }
      responses = ids.uniq.map do |id|
        valuation = positions.sum(BigDecimal("0")) { |row| BigDecimal(row.fetch(:valuation)) }
        cash = BigDecimal(cash_balance)
        overview = overview_valuation || (valuation_includes_cash ? valuation + cash : valuation)
        inventory = missing_inventory ? nil : { "items" => positions.map { |row| raw_position(row, position_currency) } }
        {
          "portfolio_id" => id,
          "overview" => {
            "account" => {
              "id" => response_account_id,
              "brokerPortfolio" => {
                "id" => response_portfolio_id || id,
                "valuation" => {
                  "valuation" => overview.to_s,
                  "securitiesValuation" => valuation.to_s,
                  "cryptoValuation" => crypto_valuation,
                  "timestampUtc" => { "time" => observed_at.iso8601 },
                  "lastInventoryUpdateTimestampUtc" => { "time" => observed_at.iso8601 }
                }
              }
            }
          },
          "cash_breakdown" => {
            "account" => {
              "id" => "broker-account",
              "brokerPortfolio" => {
                "id" => id,
                "payments" => { "buyingPower" => {
                  "cashBalance" => cash_balance,
                  "loaned" => loaned,
                  "cashAvailableToInvest" => cash_available_to_invest
                } }
              }
            }
          },
          "holdings" => {
            "account" => {
              "id" => "broker-account",
              "brokerPortfolio" => {
                "id" => id,
                "inventory" => inventory
              }
            }
          }
        }
      end

      ScalableItem::PortfolioNormalizer.new(now: now).normalize(
        discovery: discovery,
        portfolio_responses: responses,
        person_identity: "verified-person",
        connection_generation: 7,
        fetched_at: now
      )
    end

    def position(quantity: "3", valuation: "100")
      { isin: "US0378331005", name: "Synthetic Apple position", type: "EQUITY", quantity: quantity, valuation: valuation }
    end

    def raw_position(row, currency)
      {
        "isin" => row.fetch(:isin),
        "name" => row.fetch(:name),
        "type" => row.fetch(:type),
        "inventory" => { "position" => {
          "filled" => row.fetch(:quantity), "pending" => "0", "blocked" => "0", "fifoPrice" => "25"
        } },
        "portfolioIsinPerformance" => { "valuation" => row.fetch(:valuation), "currency" => currency },
        "quoteTick" => nil
      }
    end
end
