# Brings in eToro's daily prices for the instruments an eToro account holds or
# held, so that its past holdings are valued at each day's price rather than
# at the last trade's. eToro's terms let the account's own key fetch market
# data for the account's own use, so only the instruments in use are asked
# for, each from the day it was first bought, and the prices go only on
# securities no price provider covers and no other account holds or trades.
#
# eToro's date-range candles are as traded, so a split shows in them as a
# jump; its older candle history is adjusted for splits. Compared, the two
# give each instrument's splits (EtoroItem::SplitDetector). Prices are stored
# on today's shares, as eToro restates its open positions and as Sure's price
# providers store theirs, so a provider that takes a security over writes
# prices alike; no Security::Split is created, which would adjust them again.
# The splits are kept in the instrument details with the days they cover, so
# a later sync reads only the days since and checks the splits again when the
# raw closes jump, and about once a week while the instrument is held, as the
# requests a sync has to spare allow. The activities import puts closed trades
# on today's shares with them (see DataHelpers#split_factor_after).
class EtoroItem::PriceHistoryImporter
  include EtoroAccount::DataHelpers

  # Requests one sync may make; what is left waits for the next sync. A first
  # sync makes up to three for an instrument, a daily one about one for each
  # instrument still held, and a weekly split check one more.
  MAX_REQUESTS_PER_SYNC = 300

  # Requests a split check leaves to spare for a jump found later in the
  # sync: a full read, and eToro's daily and weekly split-adjusted history.
  JUMP_REQUESTS = 3

  # Days read before the first one needed, so that a split just after it
  # shows.
  LEAD_DAYS = 7

  # A move this large from one raw close to the next, either way, could be a
  # split, and has the splits checked again.
  JUMP_RATIO = BigDecimal("1.3")

  # eToro can send a session's candle hours after the session ends: an
  # instrument still without it is asked again after this long.
  REREAD_AFTER = 6.hours

  # A day eToro has not sent this many days on never comes, as on a venue's
  # holiday. A jump its split-adjusted history has not shown as a split by
  # then is a move in price.
  SETTLE_DAYS = 7

  # Days between the split checks of an instrument still held, which find a
  # split too small to make the raw closes jump, such as a bonus issue.
  SPLIT_CHECK_DAYS = 7

  # Instruments in a row eToro fails to answer for, after which the rest wait
  # for the next sync: it is down, or withholding its market data. Split
  # checks it fails to answer that many times in a row stop the same way,
  # while the reads go on.
  MAX_FAILURES_IN_A_ROW = 3

  # eToro quotes some venues in a minor unit: London in pence, Johannesburg
  # in cents, Tel Aviv in agorot.
  MINOR_UNIT_CURRENCIES = {
    "GBX" => [ "GBP", 100 ], "GBp" => [ "GBP", 100 ],
    "ZAC" => [ "ZAR", 100 ], "ZAc" => [ "ZAR", 100 ],
    "ILA" => [ "ILS", 100 ], "ILs" => [ "ILS", 100 ]
  }.freeze

  # The scale security_prices keeps prices at.
  PRICE_SCALE = 4

  # The instrument details are saved after this many instruments, so a sync
  # cut short keeps what it fetched.
  SAVE_EVERY = 25

  NEW_YORK = "America/New_York".freeze

  # What an instrument's price history records of the security it prices.
  PRICING_KEYS = %w[security_id currency written_from priced_from priced_through].freeze

  Result = Data.define(:partial_failures, :rate_limited_at)

  # One instrument's splits to check from check_from to check_through and,
  # when it prices `security`, its closes to store from price_from to
  # price_through.
  Work = Data.define(:instrument_id, :crypto, :check_from, :check_through, :security, :price_from, :price_through)

  # Whether every price written was stored, the last day written, and the
  # first day stored.
  Written = Data.define(:complete, :through, :from)

  # What a split check found: the days eToro's split-adjusted history shows a
  # split on that the splits found do not have, and the newest day compared.
  Check = Data.define(:unknown, :through)

  def self.max_requests_per_sync
    MAX_REQUESTS_PER_SYNC
  end

  # The currency of a pair eToro quotes ("LONX.l/GBX"), and how many of the
  # quoted units make one of it.
  def self.quote_currency(symbol)
    pair, slash, code = symbol.to_s.strip.rpartition("/")
    return nil if slash.empty? || pair.empty?
    return MINOR_UNIT_CURRENCIES[code] if MINOR_UNIT_CURRENCIES.key?(code)

    [ Money::Currency.new(code).iso_code, 1 ]
  rescue Money::Currency::UnknownCurrencyError
    nil
  end

  # The Sure account eToro's prices value holdings in, if any.
  def self.pricing_account(etoro_account)
    linked = etoro_account.current_account
    linked unless linked.nil? || linked.pending_deletion? || linked.disabled?
  end

  attr_reader :etoro_item, :provider

  def initialize(etoro_item, etoro_account, provider:)
    @etoro_item = etoro_item
    @etoro_account = etoro_account
    @provider = provider
    @requests = 0
    @history = {}
    @partial_failures = []
    @rate_limited_at = nil
    @missing_rates = Hash.new(0)
    @failed_instruments = []
    @failures_in_a_row = 0
    @check_failures_in_a_row = 0
    @written = {}
  end

  # Returns the failures to report, and when eToro rate limited the fetch.
  # Nothing is fetched for an account not linked to Sure, or shown by its
  # totals, which has no holdings of eToro's instruments to value; the
  # securities it priced go back to Sure.
  def import
    return result if release_unused

    works = plan
    release_unpriced(works)
    record_claims(works)
    @stored_price_ids = Security::Price.where(security_id: works.filter_map { |work| work.security&.id }).distinct.pluck(:security_id).to_set

    pending = works.select { |work| pending?(work) }.sort_by { |work| order_of(work) }
    pending.each_with_index do |work, index|
      if @requests >= self.class.max_requests_per_sync
        report_incomplete(pending.size - index)
        break
      end

      @instrument_id = work.instrument_id
      import_instrument(work, spare: spare_for_check?(pending.size - index))
      save_history! if ((index + 1) % SAVE_EVERY).zero?
    end

    finish
  rescue Provider::Etoro::RateLimitError, Provider::Etoro::TransientError, Provider::Etoro::AuthenticationError => e
    capture_failure(e)
    finish
  end

  # Hands back the securities eToro priced once the account values no
  # holdings with them: unlinked, disabled, being deleted or shown by its
  # totals. Asks eToro nothing. Returns whether it did.
  def release_unused
    return false unless account.nil? || @etoro_account.shown_as_totals?

    release(instruments_map.keys.select { |id| history_of(id)["security_id"] })
    save_history!
    true
  end

  private

    def account
      return @account if defined?(@account)

      @account = self.class.pricing_account(@etoro_account)
    end

    def provider_id
      @etoro_account.account_provider&.id
    end

    def instruments_map
      etoro_item.instruments_map
    end

    def processor
      @processor ||= EtoroAccount::PriceHistoryProcessor.new(@etoro_account)
    end

    def result
      Result.new(partial_failures: @partial_failures, rate_limited_at: @rate_limited_at)
    end

    def finish
      save_history!
      release_if_deleted
      report_missing_rates
      report_failed_instruments
      result
    end

    # Deleting the connection hands back the securities its saved price
    # histories record (see EtoroItem#release_priced_securities), so a sync
    # it was deleted during hands back those it wrote when it ends.
    def release_if_deleted
      return if @written.empty? || EtoroItem.active.exists?(etoro_item.id)

      elsewhere = etoro_item.securities_priced_elsewhere
      EtoroAccount::PriceHistoryProcessor.release(@written.values.reject { |history| elsewhere.include?(history["security_id"]) })
    end

    # A split check waits for a request to spare after a read of each
    # instrument left and the full reads of a jump among them, and for the
    # next sync once eToro has failed to answer several in a row.
    def spare_for_check?(instruments_left)
      @check_failures_in_a_row < MAX_FAILURES_IN_A_ROW &&
        @requests + instruments_left + JUMP_REQUESTS < self.class.max_requests_per_sync
    end

    # The work each real-asset instrument in use needs: its splits checked
    # when it has closed legs or prices a security, and its closes when it
    # does. Of the lines of a security eToro prices, one does both, and the
    # others' trades follow its splits (see DataHelpers#split_history_of).
    def plan
      usage = usage_by_instrument
      targets = usage.keys.index_with { |id| trade_security_for(id) }
      priced = priceable_instruments(targets)
      first_trades = first_trade_dates(priced.keys)

      usage.filter_map do |id, use|
        crypto = instrument_type_id(id) == CRYPTO_TYPE_ID
        latest = latest_session(crypto)
        security_id = targets[id]&.id
        sharing = priced[security_id]
        price_from, price_through = sharing ? price_range(usage.values_at(*sharing), latest, first_trades[security_id]) : []
        priced_here = price_from.present? && price_from <= price_through
        next if priced_here && pricing_instrument(sharing) != id

        security = targets[id] if priced_here
        price_from = price_through = nil unless security
        check_from = if crypto then nil elsif security then price_from else use[:closed].compact.min end
        check_through = security ? price_through : held_through(use, latest)
        check_from = nil if check_from && check_from > check_through
        next if check_from.nil? && security.nil?

        Work.new(
          instrument_id: id, crypto: crypto, check_from: check_from, check_through: check_through,
          security: security, price_from: price_from, price_through: price_through
        )
      end
    end

    # Real-asset instruments in use, each with the days its positions opened
    # and its closed legs ended, and whether some of it is still held.
    def usage_by_instrument
      usage = Hash.new { |hash, id| hash[id] = { opened: [], closed: [], held: false } }

      Array(@etoro_account.raw_positions_payload).each do |position|
        next unless real_asset?(position)

        use = usage[field(position, "instrumentID").to_s]
        use[:held] = true
        use[:opened] << parse_date(field(position, "openDateTime"))
      end

      Array(@etoro_account.raw_trades_payload).each do |trade|
        next unless real_asset?(trade)

        use = usage[field(trade, "instrumentID").to_s]
        use[:opened] << parse_date(field(trade, "openTimestamp"))
        use[:closed] << session_date(field(trade, "closeTimestamp"))
      end

      usage.select { |id, _| instruments_map.key?(id) }
    end

    # The instruments in use by the security each prices.
    def priceable_instruments(targets)
      candidates = targets.select { |_id, security| EtoroAccount::PriceHistoryProcessor.priceable?(security) }
      shared = shared_security_ids(candidates.values.map(&:id).uniq)

      candidates
        .reject { |_id, security| shared.include?(security.id) }
        .group_by { |_id, security| security.id }
        .transform_values { |pairs| pairs.map(&:first) }
    end

    # Securities another account holds or trades. eToro's prices would value
    # those holdings too, beyond the use eToro's terms allow.
    def shared_security_ids(security_ids)
      return Set.new if security_ids.empty?

      sharing_accounts(security_ids).map(&:first).to_set
    end

    # Each other account that holds or trades one of the securities, by
    # security. The copy accounts of this eToro account are this one, in any
    # display mode: they hold its positions, which the prices are fetched
    # for, and still do on the sync that leaves copies, as the prices are
    # imported before they are emptied.
    def sharing_accounts(security_ids)
      own = own_account_ids
      traded = Trade.joins(:entry).where(security_id: security_ids).where.not(entries: { account_id: own }).distinct.pluck(:security_id, "entries.account_id")
      held = Holding.where(security_id: security_ids).where.not(account_id: own).distinct.pluck(:security_id, :account_id)
      (traded + held).uniq
    end

    def own_account_ids
      copies = @etoro_account.copy_accounts.includes(account_provider: :account).filter_map(&:current_account)
      [ account.id, *copies.map(&:id) ].uniq
    end

    # A security eToro lists on several lines (ABCD and ABCD.RTH) takes its
    # prices from one of them, the plain listing first.
    def pricing_instrument(instrument_ids)
      instrument_ids.min_by { |id| [ us_line?(id) ? 1 : 0, id.to_i ] }
    end

    def us_line?(instrument_id)
      US_LISTING_SUFFIXES.include?(instruments_map.dig(instrument_id, "symbol").to_s.upcase.rpartition(".").last)
    end

    # From the first day bought to today, or to the last close once nothing is
    # held. The trades eToro stored in the linked account count as bought:
    # one linked to a new connection keeps those the old one stored, which the
    # new one's trade history no longer lists, and their days are priced by
    # the connection that prices the security now, so that the prices go with
    # it. A trade added by hand does not count: its shares are those of its
    # day, while eToro's prices are on today's.
    def price_range(uses, latest, first_traded)
      from = [ *uses.flat_map { |use| use[:opened] }, first_traded ].compact.min
      through = uses.any? { |use| use[:held] } ? latest : [ uses.flat_map { |use| use[:closed] }.compact.max, latest ].compact.min
      [ from, through ]
    end

    # The first day of each security's trades eToro stored in the linked
    # account.
    def first_trade_dates(security_ids)
      return {} if security_ids.empty?

      Trade.joins(:entry).where(security_id: security_ids, entries: { account_id: account.id, source: "etoro" }).group(:security_id).minimum("entries.date")
    end

    def held_through(use, latest)
      use[:held] ? latest : [ use[:closed].compact.max, latest ].compact.min
    end

    def history_of(instrument_id)
      @history[instrument_id] || price_history_of(instrument_id)
    end

    # Securities this account no longer prices go back to Sure, and the
    # instruments that priced them start afresh if they do again.
    def release_unpriced(works)
      priced = works.filter_map { |work| [ work.instrument_id, work.security.id ] if work.security }.to_h
      stale = instruments_map.keys.select do |id|
        security_id = history_of(id)["security_id"]
        security_id && priced[id] != security_id
      end

      release(stale, keeping: priced.values)
    end

    # Hands back the securities the instruments priced, apart from those
    # another instrument or another connection linked to an account now
    # prices, and clears what the instruments recorded of them. Another
    # account that holds or trades one valued it at eToro's prices until now,
    # so it is synced again without them (see PriceHistoryProcessor.release).
    def release(instrument_ids, keeping: [])
      return if instrument_ids.empty?

      keeping = keeping.to_set | etoro_item.securities_priced_elsewhere
      histories = instrument_ids.map { |id| history_of(id) }.reject { |history| keeping.include?(history["security_id"]) }
      EtoroAccount::PriceHistoryProcessor.release(histories, syncing: account)
      instrument_ids.each { |id| @history[id] = history_of(id).except(*PRICING_KEYS) }
    end

    # The security each pricing instrument prices, recorded from the start,
    # so that it goes back to Sure once this account stops pricing it
    # whether or not a price was ever stored. The security is claimed with
    # its first prices (see PriceHistoryProcessor#process).
    def record_claims(works)
      works.each do |work|
        history = history_of(work.instrument_id)
        next if work.security.nil? || history["security_id"] == work.security.id

        @history[work.instrument_id] = history.merge("security_id" => work.security.id)
      end
    end

    # Whether the instrument has days to read. Splits never checked, or not
    # from early enough, and prices for a new security or from a new first
    # day are; otherwise days not stored yet, until eToro was asked lately.
    def pending?(work)
      history = history_of(work.instrument_id)
      return true if (work.check_from && recheck?(work, history)) || (work.security && reprice?(work, history))
      return false if read_lately?(history, work.crypto)

      (work.check_from && unstored?(history["through"], work.check_through, history)) ||
        (work.security && (unstored?(history["priced_through"], work.price_through, history) || !@stored_price_ids.include?(work.security.id)))
    end

    # The splits are worked out from the start when they never were, or not
    # from early enough.
    def recheck?(work, history)
      history["splits"].nil? || history["from"].nil? || Date.iso8601(history["from"]) > work.check_from
    end

    # The prices are written afresh when another security takes them, or they
    # do not start early enough.
    def reprice?(work, history)
      history["security_id"] != work.security.id || history["priced_from"].nil? || Date.iso8601(history["priced_from"]) > work.price_from
    end

    # ...and when none are stored.
    def rewrite?(work, history)
      reprice?(work, history) || history["priced_through"].nil? || !@stored_price_ids.include?(work.security.id)
    end

    # Whether eToro was asked since the newest session ended, and lately
    # enough that a candle it sends late would not have come since.
    def read_lately?(history, crypto)
      read = history["read"].present? && Time.iso8601(history["read"])
      read.present? && read >= session_close(latest_session(crypto)) && read > REREAD_AFTER.ago
    end

    # Whether eToro may still send days up to `needed`: not all are stored,
    # and they are not a week older than the last time eToro was asked.
    def unstored?(stored, needed, history)
      return false if stored.present? && Date.iso8601(stored) >= needed

      history["read"].blank? || needed > Time.iso8601(history["read"]).to_date - SETTLE_DAYS
    end

    # Instruments not yet read first, then those read longest ago and, of
    # those, the ones whose splits were checked longest ago, so that the
    # requests a sync has to spare check each in turn, and one whose last
    # check eToro failed to answer after them, so that it does not stop
    # theirs; the longest history first. One eToro just failed on goes after
    # the others.
    def order_of(work)
      history = history_of(work.instrument_id)
      read = [ history["through"], history["priced_through"] ].compact.min.to_s
      [ history["failed"] ? 1 : 0, read, history["check_failed"] ? 1 : 0, history["checked"].to_s, (work.price_from || work.check_from).iso8601, work.instrument_id.to_i ]
    end

    # A held jump has the whole history read again, as finding its split
    # restates every price before it.
    def import_instrument(work, spare: false)
      history = history_of(work.instrument_id)
      recheck = work.check_from.present? && recheck?(work, history)
      full = recheck || history["jump"].present? || (work.security.present? && rewrite?(work, history))
      check = !full && spare && check_due?(work, history)
      raw = fetch_raw(work.instrument_id, full ? full_start(work) : resume_date(work, history, check: check))
      raw_jumps = jump_dates(work, history, raw[:closes])
      found = split_check(work, history, raw[:closes], raw_jumps) if check
      jumps = found ? (raw_jumps | found.unknown).sort : raw_jumps
      moved = work.security.present? && raw[:currency] != history["currency"]

      if (jumps.any? || moved) && !full
        full = true
        raw = fetch_raw(work.instrument_id, full_start(work))
      end
      recheck ||= jumps.any?

      splits, compared = recheck ? detect_splits(work, raw[:closes], raw_jumps) : [ stored_splits(history), found&.through ]
      held = held_jump(work, raw, jumps, splits)
      as_traded = as_traded_splits(work, raw, splits) if recheck && work.security.nil?

      # The history that records the prices as eToro's is saved with them,
      # so that a sync stopped right after can still hand them back.
      Security::Price.transaction do
        written = write_prices(work, history, raw, splits, replace: full) if work.security

        @history[work.instrument_id] = updated_history(
          work, history, raw, splits,
          recheck: recheck, compared: compared, failed_check: check && found.nil?, full: full, written: written, held: held, as_traded: as_traded
        )
        if written
          @written[work.instrument_id] = @history[work.instrument_id]
          save_history!
        end
      end
      @failures_in_a_row = 0
    rescue Provider::Etoro::RateLimitError, Provider::Etoro::AuthenticationError
      raise
    rescue Provider::Etoro::TransientError => e
      capture_instrument_failure(work, e)
      raise if (@failures_in_a_row += 1) >= MAX_FAILURES_IN_A_ROW
    rescue => e
      @failures_in_a_row = 0
      capture_instrument_failure(work, e)
    end

    def full_start(work)
      [ work.check_from && work.check_from - LEAD_DAYS, work.price_from ].compact.min
    end

    # The newest day stored, read again for the close the days after it go
    # on from. A split check reads from SETTLE_DAYS before the newest day the
    # last one compared, as eToro's split-adjusted history may not have shown
    # a split on the days before it yet, and may stop short of the closes.
    def resume_date(work, history, check: false)
      return full_start(work) if history["through"].blank?

      days = [ history["through"], (history["priced_through"] if work.security) ].compact.map { |day| Date.iso8601(day) }
      days << (history["compared"].present? ? Date.iso8601(history["compared"]) - SETTLE_DAYS : full_start(work)) if check
      days.min
    end

    # Whether an instrument still held is due to have its splits checked:
    # one too small to make its raw closes jump shows only against eToro's
    # split-adjusted history.
    def check_due?(work, history)
      latest = latest_session(work.crypto)
      work.check_from.present? && work.check_through >= latest &&
        (history["checked"].blank? || Date.iso8601(history["checked"]) <= latest - SPLIT_CHECK_DAYS)
    end

    # Compares the closes read with eToro's split-adjusted daily history (see
    # Check). Nil when eToro does not answer, or sends none of the days read:
    # the read goes on without the check, which a later sync makes. A rate
    # limit stops the sync, as on any other request.
    def split_check(work, history, closes, jumps)
      detector = EtoroItem::SplitDetector.new(closes: closes, daily: fetch_adjusted(work.instrument_id, "OneDay"), jumps: jumps)
      return check_failed(work, "eToro's split-adjusted history has none of the days read") if detector.compared_through.nil?

      @check_failures_in_a_row = 0
      capture_mismatches(work, detector)
      known = stored_splits(history).map(&:date)
      unknown = detector.splits.map(&:date).select { |date| date >= work.check_from } - known
      Check.new(unknown: unknown, through: detector.compared_through)
    rescue Provider::Etoro::RateLimitError
      raise
    rescue Provider::Etoro::ApiError => e
      check_failed(work, e.message, e)
    end

    # The days after those checked, among the ones needed, whose raw close
    # moves by about a split from the one before it, and one still waiting
    # for eToro's split-adjusted history to show its split. A first read
    # checks its newest SETTLE_DAYS, where that history may not show a split
    # yet.
    def jump_dates(work, history, closes)
      return [] unless work.check_from

      through, previous = last_checked(work, history, closes)
      jumps = closes.filter_map do |date, close|
        next if date <= through

        moved = previous&.positive? && (previous / close >= JUMP_RATIO || close / previous >= JUMP_RATIO)
        previous = close
        date if moved && date.between?(work.check_from, work.check_through)
      end
      jumps << Date.iso8601(history["jump"]) if history["jump"].present?
      jumps.uniq.sort
    end

    # The last day checked for a jump and its close.
    def last_checked(work, history, closes)
      return [ Date.iso8601(history["through"]), parse_decimal(history["close"]) ] if history["through"].present?

      settled = latest_session(work.crypto) - SETTLE_DAYS
      [ settled, closes.select { |date, _| date <= settled }.values.last ]
    end

    # The first jump no split found explains is checked again on the next
    # syncs, for eToro's split-adjusted history can take a split in after
    # its raw closes do; the jumps after it wait with it. After SETTLE_DAYS
    # a jump is a move in price.
    def held_jump(work, raw, jumps, splits)
      jumps.find do |jump|
        next false if splits.any? { |split| split.date == jump }
        next true if jump > latest_session(work.crypto) - SETTLE_DAYS && raw[:closes].keys.any? { |date| date < jump }

        capture_unexplained_jump(work, jump)
        false
      end
    end

    # eToro sends the candles that open from `from` on, and a session's opens
    # at 17:00 New York time the evening before it, so the request starts on
    # the day before the first one needed.
    def fetch_raw(instrument_id, first_day)
      @requests += 1
      data = provider.fetch_daily_candles(instrument_id.to_i, from: first_day - 1)
      symbol = field(data, "symbol")
      currency, units = self.class.quote_currency(symbol)

      { closes: raw_closes(field(data, "results")), symbol: symbol, currency: currency, units: units }
    end

    # Asked once a sync: a split check and the full one it leads to compare
    # the same candles.
    def fetch_adjusted(instrument_id, interval)
      (@adjusted ||= {})[[ instrument_id, interval ]] ||= begin
        @requests += 1
        adjusted_closes(provider.fetch_adjusted_candles(instrument_id.to_i, interval: interval))
      end
    end

    # Closes by trading day, for the days whose session has ended. Of two
    # candles for one day, the one stamped like the others, at 17:00 New York
    # time, is kept: eToro has sent a stray one beside it on other shares.
    def raw_closes(results)
      Array(results)
        .filter_map { |candle| candle_close(candle, "time") }
        .group_by { |time, _| session_date(time) }
        .select { |date, _| date && session_close(date) <= Time.current }
        .transform_values { |candles| candles.max_by { |time, _| [ usual_stamp?(time) ? 1 : 0, time ] }.last }
        .sort.to_h
    end

    def adjusted_closes(candles)
      Array(candles).filter_map { |candle| candle_close(candle, "fromDate") }.to_h { |time, close| [ session_date(time), close ] }
    end

    def candle_close(candle, stamp)
      time = parse_time(field(candle, stamp))
      close = parse_decimal(field(candle, "close"))
      [ time, close ] if time && close&.positive?
    rescue ArgumentError
      nil
    end

    def detect_splits(work, closes, jumps)
      return [ [], nil ] if closes.empty?

      daily = required_adjusted(work.instrument_id, "OneDay")
      weekly = work.check_from < daily.keys.min ? required_adjusted(work.instrument_id, "OneWeek") : {}
      detector = EtoroItem::SplitDetector.new(closes: closes, daily: daily, weekly: weekly, jumps: jumps)
      capture_mismatches(work, detector)

      # A split switching on the first day needed decides the shares of a
      # leg closed that day (see DataHelpers#split_factor_after).
      [ detector.splits.select { |split| split.date >= work.check_from }, detector.compared_through ]
    end

    # The split-adjusted candles a full check of the closes read needs. The
    # splits it finds replace the ones stored, so an answer without them
    # would drop the splits they show: the instrument waits for a sync eToro
    # sends them on.
    def required_adjusted(instrument_id, interval)
      fetch_adjusted(instrument_id, interval).presence ||
        raise(Provider::Etoro::TransientError, "eToro sent no split-adjusted #{interval == "OneDay" ? "daily" : "weekly"} candles")
    end

    def stored_splits(history)
      Array(history["splits"]).map do |on, ratio, close|
        EtoroItem::SplitDetector::Split.new(Date.iso8601(on), Rational(ratio), parse_decimal(close))
      end
    end

    # The splits the closed trades of a security a price provider prices
    # stay off: the provider stored its prices across them before they
    # happened, and Sure keeps a stored price as it is, so the days before
    # them are priced on the shares of the time. A price stored after a split,
    # or not stored yet, is on today's shares.
    def as_traded_splits(work, raw, splits)
      security = trade_security_for(work.instrument_id)
      return [] if security.nil? || raw[:currency].nil?

      splits.select do |split|
        day = raw[:closes].keys.reverse_each.find { |date| date < split.date }
        stored = day && Security::Price.where(security_id: security.id, date: day, currency: raw[:currency]).pick(:price)
        next false unless stored&.positive?

        traded = raw[:closes][day] / raw[:units]
        EtoroItem::SplitDetector.distance(stored, traded) < EtoroItem::SplitDetector.distance(stored * split.ratio, traded)
      end
    end

    # Writes the prices the work needs, all of them when the splits or the
    # security are new, on every calendar day from the first close to the
    # last: a day without a session takes the close before it, as Sure's price
    # imports store prices, or it is valued at whatever price its holding had
    # when the history was last worked out. Nil when it can store nothing:
    # eToro quotes a currency Sure does not know, or the security is no longer
    # one eToro may price (see PriceHistoryProcessor#process).
    def write_prices(work, history, raw, splits, replace:)
      return capture_unknown_currency(work, raw[:symbol]) unless raw[:currency]

      from = replace ? work.price_from : Date.iso8601(history["priced_through"]) + 1
      closes = raw[:closes].to_h { |date, close| [ date, adjusted_price(close, date, splits, raw[:units]) ] }
      prices = every_day(closes).select { |date, _| date >= from && date <= work.price_through }
      written = processor.process(work.security, currency: raw[:currency], closes: prices, replace: replace)
      return if written.nil?

      @missing_rates[raw[:currency]] += written.missing_rates
      Written.new(complete: written.missing_rates.zero?, through: prices.keys.max, from: written.first_date)
    end

    def every_day(closes)
      return {} if closes.empty?

      price = nil
      (closes.keys.first..closes.keys.last).each_with_object({}) do |day, prices|
        price = closes.fetch(day, price)
        prices[day] = price
      end
    end

    # A close on today's shares, in the currency's whole units.
    def adjusted_price(close, date, splits, units)
      factor = splits.reduce(Rational(1)) { |product, split| split.date > date ? product * split.ratio : product }
      (close * factor.denominator / (factor.numerator * units)).round(PRICE_SCALE)
    end

    # What the read leaves: the newest session read and its close, short of
    # a held jump, the session of the last split check and the newest day it
    # compared, or that eToro failed to answer the last one, the first day
    # eToro's prices were stored on the security, in its currency, and the
    # newest day priced when every price went in.
    def updated_history(work, history, raw, splits, recheck:, compared:, failed_check:, full:, written:, held:, as_traded:)
      updated = history.except("failed", "jump")
      updated["read"] = Time.current.iso8601

      if work.check_from
        updated["splits"] = splits.map { |split| [ split.date.iso8601, ratio_text(split.ratio), split.close&.to_s("F") ].compact }
        updated["from"] = work.check_from.iso8601 if recheck
        if compared
          updated["checked"] = latest_session(work.crypto).iso8601
          updated["compared"] = compared.iso8601
          updated.delete("check_failed")
        elsif failed_check
          updated["check_failed"] = Time.current.iso8601
        end
      end
      updated["as_traded"] = as_traded.map { |split| split.date.iso8601 } unless as_traded.nil?
      updated.delete("as_traded") if work.security

      through = held ? raw[:closes].keys.select { |date| date < held }.max : raw[:closes].keys.last
      if through
        updated["through"] = through.iso8601
        updated["close"] = raw[:closes][through].to_s
      end
      updated["jump"] = held.iso8601 if held

      # A write in another currency dropped the prices in the one before; one
      # that stored none kept them, and the history goes on recording them.
      switched = raw[:currency] != history["currency"]
      if work.security && written && !(switched && written.from.nil? && history["currency"].present?)
        updated.delete("written_from") if switched
        updated["security_id"] = work.security.id
        updated["currency"] = raw[:currency]
        updated["written_from"] = [ updated["written_from"], written.from.iso8601 ].compact.min if written.from
        if written.complete
          updated["priced_from"] = work.price_from.iso8601 if full
          updated["priced_through"] = written.through.iso8601 if written.through
        end
      end

      updated
    end

    def ratio_text(ratio)
      ratio.denominator == 1 ? ratio.numerator.to_s : ratio.to_s
    end

    def save_history!
      return if @history.empty?

      instruments = instruments_map.to_h do |id, details|
        @history.key?(id) && details.is_a?(Hash) ? [ id, details.merge("price_history" => @history[id]) ] : [ id, details ]
      end
      etoro_item.update!(raw_instruments_payload: instruments)
      @history.clear
    end

    # The newest trading day whose session has ended. Stocks trade on
    # weekdays; a venue's holidays only show as days eToro sends nothing for.
    def latest_session(crypto)
      now = Time.current.in_time_zone(NEW_YORK)
      day = now.hour >= 17 ? now.to_date : now.to_date.prev_day
      day = day.prev_day until crypto || day.on_weekday?
      day
    end

    def session_close(date)
      ActiveSupport::TimeZone[NEW_YORK].local(date.year, date.month, date.day, 17)
    end

    def usual_stamp?(time)
      local = time.in_time_zone(NEW_YORK)
      local.hour == 17 && local.min.zero?
    end

    def report_incomplete(count)
      @partial_failures << { what: :price_history, message: I18n.t("etoro_items.sync.partial_failures.price_history_incomplete", count: count) }
    end

    def report_missing_rates
      @missing_rates.each do |currency, count|
        next unless count.positive?

        @partial_failures << {
          what: :price_history,
          message: I18n.t("etoro_items.sync.partial_failures.price_history_missing_rates", currency: currency, count: count)
        }
      end
      @missing_rates.clear
    end

    def report_failed_instruments
      return if @failed_instruments.empty?

      @partial_failures << {
        what: :price_history,
        message: I18n.t("etoro_items.sync.partial_failures.price_history_instruments_failed", count: @failed_instruments.size)
      }
      @failed_instruments.clear
    end

    def capture_failure(error)
      @rate_limited_at ||= Time.current if error.is_a?(Provider::Etoro::RateLimitError)
      @partial_failures << { what: :price_history, message: error.message }

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::PriceHistoryImporter - Stopped fetching price history: #{error.message}. The next sync continues.",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { instrument_id: @instrument_id, status_code: error.try(:status_code), error_class: error.class.name, requests: @requests }
      )
    end

    # The instrument is asked after the others on the next sync, so that one
    # eToro keeps failing on does not hold them up.
    def capture_instrument_failure(work, error)
      @failed_instruments << work.instrument_id
      @history[work.instrument_id] = history_of(work.instrument_id).merge("failed" => Time.current.iso8601)

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::PriceHistoryImporter - Failed to fetch the price history of instrument #{work.instrument_id}: #{error.message}",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { instrument_id: work.instrument_id, status_code: error.try(:status_code), error_class: error.class.name }
      )
    end

    # A split check eToro does not answer is made on a later sync; after
    # MAX_FAILURES_IN_A_ROW in a row, the others this sync wait too.
    def check_failed(work, message, error = nil)
      @check_failures_in_a_row += 1

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::PriceHistoryImporter - Could not check instrument #{work.instrument_id} for splits: #{message}. A later sync checks again.",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { instrument_id: work.instrument_id, status_code: error.try(:status_code), error_class: error&.class&.name }
      )
      nil
    end

    # The changes of basis no split explains, from the first day needed.
    def capture_mismatches(work, detector)
      mismatches = detector.mismatches.select { |mismatch| mismatch.date >= work.check_from }
      return if mismatches.empty?

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::PriceHistoryImporter - eToro's prices of instrument #{work.instrument_id} change share basis by a ratio no split has; not applied.",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: {
          instrument_id: work.instrument_id,
          changes: mismatches.first(20).map { |mismatch| { date: mismatch.date.iso8601, ratio: mismatch.ratio.to_f.round(6) } }
        }
      )
    end

    def capture_unexplained_jump(work, jump)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::PriceHistoryImporter - eToro's prices of instrument #{work.instrument_id} jumped on #{jump.iso8601}, " \
                 "and its split-adjusted history shows no split; taken as a move in price.",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { instrument_id: work.instrument_id, date: jump.iso8601 }
      )
    end

    def capture_unknown_currency(work, symbol)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::PriceHistoryImporter - eToro quotes instrument #{work.instrument_id} as #{symbol.inspect}, in a currency Sure does not know; its prices are not stored.",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { instrument_id: work.instrument_id, symbol: symbol }
      )
      nil
    end
end
