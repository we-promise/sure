# The list of sections the portfolio hub renders, in the order the user last
# left them.
#
# Same shape as ReportsController#build_reports_sections -- a hash per section
# with `key`, an i18n `title` key, a `partial`, its `locals`, and the `visible`
# / `collapsible` flags -- so the Reports section chrome (drag to reorder,
# chevron to collapse) renders it unchanged. It lives here rather than in the
# controller because the ordering rule and the section list are domain
# decisions the controller only renders, and because a PORO can be unit-tested
# without a request.
#
# Every local a partial needs is passed in. Nothing here (and nothing in the
# partials) reads Date.current or Current.family: the controller captures one
# `as_of` and one statement per request and hands them down, so the sections
# that take a date all read the same one.
class Portfolio::SectionRegistry
  # The built-in section keys, in declaration order. The preferences
  # endpoint accepts only these, so a saved order or collapsed set cannot
  # carry arbitrary strings into the user's preferences.
  KEYS = %w[holdings accounts].freeze

  # Everything an account card's logo reads, preloaded onto the cards.
  CARD_PRELOADS = [ { logo_attachment: :blob }, :accountable, :plaid_account, :simplefin_account, { account_providers: :provider } ].freeze

  attr_reader :statement, :period, :as_of, :user, :sort, :dir, :extra_sections

  # `sort` and `dir` are the holdings table's query-string state, passed
  # through as given: the statement whitelists them
  # (InvestmentStatement::HOLDINGS_SORT_KEYS, HOLDINGS_SORT_DIRECTIONS) and
  # falls back to its defaults for anything else.
  #
  # `extra_sections` are appended after the built-ins, in the order given. It
  # is the seam that keeps this list open: a section can be added (or a test
  # can add one) without editing the built-in list.
  def initialize(statement:, period:, as_of:, user:, sort: nil, dir: nil, extra_sections: [])
    @statement = statement
    @period = period
    @as_of = as_of
    @user = user
    @sort = sort
    @dir = dir
    @extra_sections = extra_sections || []
  end

  # True when the viewer counts no investment account; the page shows its
  # empty state instead of the sections. Reads the same loaded list as the
  # cards, so the accounts are queried once per request.
  def empty?
    accounts_for_cards.empty?
  end

  def sections
    all = built_in_sections + extra_sections

    # Order by the user's saved order; anything the saved order doesn't
    # mention (a section added since they last dragged one) is appended in
    # declaration order, so a new section always appears rather than
    # disappearing until the next drag. Same rule as Reports.
    # `uniq` before the lookup: a saved order that repeats a key would
    # otherwise render that section once per occurrence. The endpoint
    # deduplicates what it writes, but an order written by anything else
    # still has to render once.
    ordered = Array(user&.section_order("portfolio")).uniq.filter_map do |key|
      all.find { |section| section[:key] == key }
    end

    # Matched by key, never by comparing whole section hashes: a section's
    # locals carry the statement and whatever it has memoised, and the order
    # must not depend on how those compare.
    placed = ordered.map { |section| section[:key] }
    ordered + all.reject { |section| placed.include?(section[:key]) }
  end

  private
    def built_in_sections
      [
        {
          key: "holdings",
          title: "portfolios.sections.holdings",
          partial: "portfolios/holdings",
          locals: shared_locals.merge(rows: holdings_rows, sort: holdings_sort.first, dir: holdings_sort.last),
          visible: holdings_rows.any?,
          collapsible: true
        },
        {
          key: "accounts",
          title: "portfolios.sections.accounts",
          partial: "portfolios/accounts",
          locals: shared_locals.merge(accounts: accounts_for_cards),
          visible: accounts_for_cards.any?,
          collapsible: true
        }
      ]
    end

    def holdings_rows
      @holdings_rows ||= statement.holdings_table_rows(sort: holdings_sort.first, dir: holdings_sort.last)
    end

    # The sort the statement applies, so the view marks the header the rows
    # are ordered by even when the requested one fell back.
    def holdings_sort
      @holdings_sort ||= InvestmentStatement.holdings_sort(sort, dir)
    end

    # The accounts the cards show, in name order, with every record the logo
    # reads (the attachment, the accountable's colour, the
    # provider links and the provider each falls back to) loaded here rather
    # than once per card.
    #
    # They are the statement's own records rather than a second query: the
    # holdings section's weights load the same accounts through the
    # statement, and the page reads them once. So they are sorted here, by
    # name with its accent marks and case set aside (an accented name sits
    # with its letter, not after "z"). Only combining marks are dropped, so a
    # name with no Latin form keeps its characters; id settles same-named
    # cards.
    def accounts_for_cards
      @accounts_for_cards ||= begin
        accounts = statement.investment_accounts.to_a.sort_by do |account|
          [ account.name.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase, account.id ]
        end
        ActiveRecord::Associations::Preloader.new(records: accounts, associations: CARD_PRELOADS).call
        accounts
      end
    end

    def shared_locals
      { statement: statement, period: period, as_of: as_of }
    end
end
