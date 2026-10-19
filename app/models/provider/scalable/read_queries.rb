# frozen_string_literal: true

module Provider::Scalable::ReadQueries
  # based on the official ScalableCapital/scalable-cli read documents at d37db02f5dd0d88d8f161938614be2daec2a2741
  RESOLVE_BROKER_IDS = <<~GRAPHQL.freeze
    query ResolveBrokerIds($id: ID!) {
      account(id: $id) {
        id
        brokerPortfolios {
          id
        }
      }
    }
  GRAPHQL

  BROKER_OVERVIEW = <<~GRAPHQL.freeze
    query BrokerOverview($accountId: ID!, $portfolioId: ID!, $includeYearToDate: Boolean!) {
      account(id: $accountId) {
        id
        brokerPortfolio(id: $portfolioId) {
          id
          valuation(includeYearToDate: $includeYearToDate) {
            valuation
            securitiesValuation
            cryptoValuation
            timestampUtc {
              time
            }
            lastInventoryUpdateTimestampUtc {
              time
            }
            timeWeightedReturnByTimeframe {
              timeframe
              simpleAbsoluteReturn
            }
          }
        }
      }
    }
  GRAPHQL

  BROKER_CASH_BREAKDOWN = <<~GRAPHQL.freeze
    query BrokerLimits($accountId: ID!, $portfolioId: ID!) {
      account(id: $accountId) {
        id
        brokerPortfolio(id: $portfolioId) {
          id
          depositLimits {
            min
            max
          }
          withdrawalLimits {
            min
            max
            maxExcludingCredit
          }
          payments {
            buyingPower {
              cashBalance
              liveLimit
              loaned
              pendingBuyOrdersAmount
              pendingWithdrawalsAmount
              pendingSavingsPlanAmount
              pendingDividendsReinvestmentAmount
              pendingPocketMoneyAmount
              estimatedTaxes
              directDebit
              cashAvailableToInvest
              cashAvailableToInvestWithoutCredit
            }
            derivativesBuyingPower {
              cashAvailableToInvest
              derivativesDirectDebit
              pendingELTIFAmount
              cashAvailableForDerivatives
            }
            withdrawalPower {
              cashAvailableToInvest
              sellTradesAmount
              withdrawalDirectDebit
              cashAvailableForWithdrawal
            }
          }
        }
      }
    }
  GRAPHQL

  BROKER_HOLDINGS = <<~GRAPHQL.freeze
    query BrokerHoldings(
      $accountId: ID!
      $portfolioId: ID!
      $includeYearToDate: Boolean!
      $quoteSource: MarketDataSource
    ) {
      account(id: $accountId) {
        id
        brokerPortfolio(id: $portfolioId) {
          id
          inventory {
            items {
              isin
              name
              type
              inventory {
                position {
                  filled
                  pending
                  blocked
                  fifoPrice
                }
              }
              portfolioIsinPerformance {
                valuation
                currency
              }
              quoteTick(source: $quoteSource, includeYearToDate: $includeYearToDate) {
                midPrice
                currency
                timestampUtc {
                  time
                }
                isOutdated
              }
            }
          }
        }
      }
    }
  GRAPHQL

  DOCUMENTS = {
    broker_portfolios: { name: "ResolveBrokerIds", query: RESOLVE_BROKER_IDS }.freeze,
    broker_overview: { name: "BrokerOverview", query: BROKER_OVERVIEW }.freeze,
    broker_cash_breakdown: { name: "BrokerLimits", query: BROKER_CASH_BREAKDOWN }.freeze,
    broker_holdings: { name: "BrokerHoldings", query: BROKER_HOLDINGS }.freeze
  }.freeze
end
