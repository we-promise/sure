# frozen_string_literal: true

# Some Akahu connections report a single account that actually holds several
# managed funds, with the per-fund breakdown under `meta.portfolio`. Kernel
# Wealth is the clearest example: one "Portfolio" account containing five funds.
#
# Other connections already expose one account per fund — Simplicity sends
# "Growth Fund" and "Kiwisaver" as separate accounts, each with a single
# portfolio entry. That shape works well in Sure: every fund gets its own
# account, its own balance, and therefore its own accumulating balance history.
#
# This splitter brings the first shape in line with the second by deriving a
# synthetic account per fund, so multi-fund connections gain per-fund visibility
# and per-fund history instead of a single blended balance.
#
# Splitting is deliberately conservative. It only applies when the payload looks
# like a basket of managed funds:
#
#   * at least two portfolio entries (a single entry is already its own account)
#   * no entry carries a `symbol`
#
# The second condition keeps exchange-listed positions out. Sharesies and
# Sharesight report holdings with real tickers ("SPK"), and individual listed
# securities belong in Sure as holdings against a brokerage account, not as
# separate accounts.
class AkahuAccount::PortfolioSplitter
  SEPARATOR = AkahuAccount::SYNTHETIC_ID_SEPARATOR

  def initialize(account_data)
    @data = account_data.respond_to?(:with_indifferent_access) ? account_data.with_indifferent_access : {}
  end

  def split?
    return false if parent_id.blank?
    return false if funds.size < 2

    funds.none? { |fund| fund[:symbol].present? }
  end

  # Returns one synthetic account payload per fund, shaped like a regular Akahu
  # account so the rest of the import path needs no special handling.
  def split
    return [] unless split?

    funds.filter_map do |fund|
      key = fund_key(fund)
      next if key.blank?

      build_account(fund, key)
    end
  end

  private

    attr_reader :data

    def parent_id
      @parent_id ||= (data[:_id].presence || data[:id].presence).to_s
    end

    def funds
      @funds ||= begin
        meta = data[:meta]
        entries = meta.is_a?(Hash) ? meta.with_indifferent_access[:portfolio] : nil
        Array(entries).select { |entry| entry.is_a?(Hash) }.map(&:with_indifferent_access)
      end
    end

    def fund_key(fund)
      (fund[:fund_id].presence || fund[:name].presence).to_s.strip.gsub(/\s+/, "-")
    end

    def build_account(fund, key)
      {
        "_id" => [ parent_id, key ].join(SEPARATOR),
        "name" => fund[:name].presence || key,
        "type" => data[:type],
        "status" => data[:status],
        "balance" => {
          "current" => fund[:value],
          "currency" => fund[:currency].presence || data.dig(:balance, :currency)
        }.compact,
        "connection" => data[:connection],
        "refreshed" => data[:refreshed],
        "meta" => {
          # Retained so the account can still be traced back to the Akahu
          # account it was derived from, and so the single-fund payload stays
          # available to anything that reads meta.portfolio.
          "akahu_parent_account" => parent_id,
          "portfolio" => [ fund ]
        }
      }.compact
    end
end
