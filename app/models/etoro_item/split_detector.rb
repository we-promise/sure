# Finds the splits in an instrument's history by comparing eToro's raw daily
# closes with its split-adjusted ones. Their ratio on a day is how many of
# today's shares one share of that day has become: it steps at each split and
# holds between them. eToro's adjusted closes are daily over its newest 1000
# trading days and weekly before that. A day is compared with its own raw
# close, which it matches to the rounding of the adjusted close; a week on
# its last trading day in the raw closes, which can be a day off and so
# differ by that day's move. A split found between two weeks goes on the day
# within them the raw closes move most nearly by its ratio, or on two days
# when it is two splits in one week.
class EtoroItem::SplitDetector
  # New shares per old share: n for 1 and 1 for n up to 1000, and 3 or 5
  # for 2. A step that matches none of these is not taken for a split.
  RATIOS = ((2..1000).map { |shares| Rational(shares) } + [ Rational(3, 2), Rational(5, 2) ])
    .then { |forward| forward + forward.map { |ratio| 1 / ratio } }
    .freeze
  RATIO_SET = RATIOS.to_set.freeze

  # Bonus issues of one new share for every 3, 4, 5, 10 or 20 held. Only
  # daily closes tell them from a day's move.
  BONUS_RATIOS = [ 3, 4, 5, 10, 20 ].map { |held| Rational(held + 1, held) }
    .then { |forward| forward + forward.map { |ratio| 1 / ratio } }
    .freeze

  # Two daily ratios within this of each other are on one basis, and a step
  # between daily ones within this of a ratio is that ratio.
  DAILY_TOLERANCE = 0.01

  # Weeks are on one basis within this, and a step involving a week is the
  # ratio it is within WEEKLY_SNAP of.
  WEEKLY_SAME_BASIS = 0.1
  WEEKLY_SNAP = 0.05

  # eToro rounds its adjusted closes to four places, which below this is too
  # coarse to tell the basis by.
  MIN_ADJUSTED = BigDecimal("0.01")

  # `close` is the raw close of `date`, the first trading day on the new
  # shares.
  Split = Data.define(:date, :ratio, :close)
  # A step in the basis that is no split ratio, from the day before `date`.
  Mismatch = Data.define(:date, :ratio)
  Observation = Data.define(:date, :ratio, :daily)

  # Observations in a row on the same basis. Weeks come before days, so a
  # run's days give the basis at its end and its weeks the basis at its start.
  Run = Struct.new(:observations) do
    def first_date = observations.first.date
    def last_date = observations.last.date
    def daily_end? = observations.last.daily
    def daily_start? = observations.first.daily
    def end_basis = median(observations.select(&:daily).presence || observations)
    def start_basis = median(observations.reject(&:daily).presence || observations)

    def median(list)
      list.map(&:ratio).sort[list.size / 2]
    end
  end

  # compared_through is the newest day the daily split-adjusted closes give
  # the basis of, nil when they give none.
  attr_reader :splits, :mismatches, :compared_through

  # Whether `step` is a split ratio, and which: within DAILY_TOLERANCE when
  # it is between daily closes, else within WEEKLY_SNAP.
  def self.snap(step, daily:)
    candidates = daily ? RATIOS + BONUS_RATIOS : RATIOS
    ratio = candidates.min_by { |candidate| distance(step, candidate) }
    ratio if distance(step, ratio) <= Math.log(1 + (daily ? DAILY_TOLERANCE : WEEKLY_SNAP))
  end

  def self.distance(value, other)
    (Math.log(value.to_f) - Math.log(other.to_f)).abs
  end

  # closes and daily are BigDecimal closes by trading day; weekly by the first
  # trading day of each week, closing at its last trading day's close. jumps
  # are the days the raw closes jump on.
  def initialize(closes:, daily:, weekly: {}, jumps: [])
    @closes = closes.sort.to_h
    @days = @closes.keys
    @daily = daily
    @weekly = weekly.sort.to_h
    @jumps = jumps.to_set
    @splits = []
    @mismatches = []
    detect
  end

  private

    def detect
      kept = without_glitches(runs)
      kept.pop while unsettled?(kept)
      @compared_through = kept.last&.observations&.reverse_each&.find(&:daily)&.date

      kept.each_cons(2) do |before, after|
        step = before.end_basis / after.start_basis
        daily = before.daily_end? && after.daily_start?
        ratio = self.class.snap(step, daily: daily)

        if ratio
          placements(before.last_date, after.first_date, ratio).each { |date, part| @splits << Split.new(date, part, @closes[date]) }
        else
          @mismatches << Mismatch.new(after.first_date, step)
        end
      end
    end

    # The newest observation alone off the basis of the ones before it, by no
    # split's ratio or by a bonus issue's the raw closes do not jump with, is
    # as likely a bad day in one of the series: it is left until a day after
    # it shows which. A larger split moves the raw closes by its ratio.
    def unsettled?(runs)
      return false unless runs.size >= 2 && runs.last.observations.one?

      before, after = runs.last(2)
      ratio = self.class.snap(before.end_basis / after.start_basis, daily: before.daily_end? && after.daily_start?)
      ratio.nil? || (BONUS_RATIOS.include?(ratio) && !@jumps.include?(after.first_date))
    end

    def runs
      observations.each_with_object([]) do |observation, runs|
        last = runs.last&.observations&.last
        if last && same_basis?(last.ratio, observation.ratio, daily: last.daily && observation.daily)
          runs.last.observations << observation
        else
          runs << Run.new([ observation ])
        end
      end
    end

    # A single observation off the basis on both sides of it is a bad day in
    # one series, not a split and its reversal.
    def without_glitches(runs)
      runs.each_with_object([]) do |run, kept|
        if kept.size >= 2 && kept.last.observations.one? &&
            same_basis?(kept[-2].end_basis, run.start_basis, daily: kept[-2].daily_end? && run.daily_start?)
          kept.pop
          kept.last.observations.concat(run.observations)
        else
          kept << run
        end
      end
    end

    def observations
      first_daily = @daily.keys.min
      daily = @closes.filter_map { |date, close| observation(date, close, @daily[date], daily: true) }

      (weekly_observations(first_daily) + daily).sort_by(&:date)
    end

    # Each week wholly before the daily window, on its last trading day in the
    # raw closes.
    def weekly_observations(first_daily)
      starts = @weekly.keys
      starts.each_with_index.filter_map do |start, index|
        finish = starts[index + 1] || start + 7
        next if first_daily && finish > first_daily

        last_day = last_day_before(finish)
        observation(last_day, @closes[last_day], @weekly[start], daily: false) if last_day && last_day >= start
      end
    end

    def observation(date, close, adjusted, daily:)
      Observation.new(date, close / adjusted, daily) if close&.positive? && adjusted && adjusted >= MIN_ADJUSTED
    end

    def last_day_before(date)
      index = @days.bsearch_index { |day| day >= date } || @days.size
      @days[index - 1] if index.positive?
    end

    def same_basis?(ratio, other, daily:)
      self.class.distance(ratio, other) <= Math.log(1 + (daily ? DAILY_TOLERANCE : WEEKLY_SAME_BASIS))
    end

    # The trading days after `before`, up to `after`, the split goes on, with
    # the ratio each takes: the day the raw closes move most nearly by its
    # ratio, or two days whose moves make it up more nearly, as two splits in
    # one week. A move on another day, however large, is the market's.
    def placements(before, after, ratio)
      start = @days.bsearch_index { |day| day > before }
      days = start ? @days[start..].take_while { |day| day <= after } : []
      return [ [ after, ratio ] ] if days.size <= 1

      moves = log_moves(before, days)
      single = days.map { |day| [ (moves[day] - Math.log(ratio)).abs, [ [ day, ratio ] ] ] }
      double = ratio_pairs(ratio).flat_map do |first, second|
        days.combination(2).map do |early, late|
          [ (moves[early] - Math.log(first)).abs + (moves[late] - Math.log(second)).abs, [ [ early, first ], [ late, second ] ] ]
        end
      end

      (single + double).min_by(&:first).last
    end

    # How far each day's raw close moved from the trading day before it, as
    # the log of their ratio.
    def log_moves(before, days)
      previous = @closes[before]
      days.to_h do |day|
        move = previous.positive? && @closes[day].positive? ? Math.log((previous / @closes[day]).to_f) : 0.0
        previous = @closes[day]
        [ day, move ]
      end
    end

    # The two splits the same way that make up `ratio`.
    def ratio_pairs(ratio)
      RATIOS.filter_map do |first|
        second = ratio / first
        [ first, second ] if (first > 1) == (ratio > 1) && (second > 1) == (ratio > 1) && RATIO_SET.include?(second)
      end
    end
end
