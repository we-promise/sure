class UI::AccountPage < ApplicationComponent
  attr_reader :account, :chart_view, :chart_period, :statement_coverage, :statements, :reconciliation_statuses,
              :can_manage_statements

  renders_one :activity_feed, ->(feed_data:, pagy:, search:) { UI::Account::ActivityFeed.new(feed_data: feed_data, pagy: pagy, search: search) }

  def initialize(account:, chart_view: nil, chart_period: nil, active_tab: nil, statement_coverage: nil, statements: [],
                 reconciliation_statuses: {}, can_manage_statements: false)
    @account = account
    @chart_view = chart_view
    @chart_period = chart_period
    @active_tab = active_tab
    @statement_coverage = statement_coverage
    @statements = statements
    @reconciliation_statuses = reconciliation_statuses
    @can_manage_statements = can_manage_statements
  end

  def id
    dom_id(account, :container)
  end

  def broadcast_channel
    account
  end

  def broadcast_refresh!
    Turbo::StreamsChannel.broadcast_replace_to(broadcast_channel, target: id, renderable: self, layout: false)
  end

  def title
    account.name
  end

  def subtitle
    return nil unless account.property?

    account.property.address
  end

  def active_tab
    tabs.find { |tab| tab == @active_tab&.to_sym } || tabs.first
  end

  def tabs
    base_tabs = case account.accountable_type
    when "Investment", "Crypto"
      [ :activity, :holdings ]
    when "Property", "Vehicle"
      [ :activity, :overview ]
    when "Loan"
      loan_tabs
    else
      [ :activity ]
    end

    base_tabs + [ :statements ]
  end

  def fx_coverage_start_date
    return @fx_coverage_start_date if defined?(@fx_coverage_start_date)

    result = nil
    if account.family.present? && account.currency != account.family.currency
      pair = ExchangeRatePair.for_pair(from: account.currency, to: account.family.currency)
      if pair.first_provider_rate_on.present?
        oldest_entry = account.entries.minimum(:date)
        if oldest_entry.present? && oldest_entry < pair.first_provider_rate_on
          result = pair.first_provider_rate_on
        end
      end
    end

    @fx_coverage_start_date = result
  end

  def tab_content_for(tab)
    case tab
    when :activity
      activity_feed
    when :holdings, :overview
      # Accountable is responsible for implementing the partial in the correct folder
      render "#{account.accountable_type.downcase.pluralize}/tabs/#{tab}", account: account
    when :schedule
      render_schedule_tab
    when :statements
      render_statement_tab
    end
  end

  def render_statement_tab
    return render "accounts/show/statements_frame", **statement_tab_locals if statement_tab_loaded?

    turbo_frame_tag statement_tab_frame_id, src: helpers.account_path(account, tab: "statements"), loading: :lazy
  end

  def statement_tab_loaded?
    statement_coverage.present?
  end

  def statement_tab_frame_id
    dom_id(account, :statements_tab)
  end

  def statement_tab_locals
    {
      account: account,
      coverage: statement_coverage,
      statements: statements,
      reconciliation_statuses: reconciliation_statuses,
      can_manage_statements: can_manage_statements
    }
  end

  # Mirrors render_statement_tab: the eager branch renders through the frame
  # partial rather than the bare template, so a <turbo-frame> element is always
  # present. Without it a form inside the schedule tab auto-scopes to nothing
  # when that tab is active on initial load, and Turbo falls back to a full
  # page navigation on submit. Cherry-picked from #4 per #7's scope -- it is an
  # independent bug fix and should not wait for that PR's fate.
  def render_schedule_tab
    return render "accounts/show/schedule_frame", account: account if active_tab == :schedule

    turbo_frame_tag schedule_tab_frame_id,
                    src: helpers.account_path(account, tab: "schedule"),
                    loading: :lazy
  end

  def schedule_tab_frame_id
    dom_id(account, :schedule_tab)
  end

  private
    # Only show the Schedule tab when the loan actually has a schedule to
    # show -- e.g. not for a loan missing a rate or term.
    def loan_tabs
      base = [ :overview, :activity ]
      base << :schedule if account.loan&.amortizable?
      base
    end
end
