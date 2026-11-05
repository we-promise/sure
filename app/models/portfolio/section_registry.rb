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
  KEYS = %w[accounts].freeze

  attr_reader :statement, :period, :as_of, :user, :extra_sections

  # `extra_sections` are appended after the built-ins, in the order given. It
  # is the seam that keeps this list open: a section can be added (or a test
  # can add one) without editing the built-in list.
  def initialize(statement:, period:, as_of:, user:, extra_sections: [])
    @statement = statement
    @period = period
    @as_of = as_of
    @user = user
    @extra_sections = extra_sections || []
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
          key: "accounts",
          title: "portfolios.sections.accounts",
          partial: "portfolios/accounts",
          locals: shared_locals.merge(accounts: accounts_for_cards),
          visible: statement.investment_accounts.any?,
          collapsible: true
        }
      ]
    end

    # The accounts the cards show, in name order, with every record the logo
    # reads (the attachment, the accountable's colour, the provider links and
    # the provider each falls back to) loaded here rather than once per card.
    def accounts_for_cards
      statement.investment_accounts.with_attached_logo
        .includes(:accountable, :plaid_account, :simplefin_account, account_providers: :provider)
        .alphabetically.to_a
    end

    def shared_locals
      { statement: statement, period: period, as_of: as_of }
    end
end
