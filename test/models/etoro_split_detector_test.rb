require "test_helper"

class EtoroSplitDetectorTest < ActiveSupport::TestCase
  test "a split within the daily window goes on the first day eToro's raw closes are on the new basis" do
    split_on = Date.new(2026, 7, 1)
    adjusted = prices(weekdays(Date.new(2026, 5, 4), Date.new(2026, 8, 28)))
    raw = adjusted.to_h { |day, price| [ day, day < split_on ? price * 4 : price ] }

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: adjusted)

    assert_equal [ [ split_on, Rational(4) ] ], found(detector)
    assert_empty detector.mismatches
  end

  test "a reverse split is a ratio below one" do
    split_on = Date.new(2026, 7, 14)
    adjusted = prices(weekdays(Date.new(2026, 5, 4), Date.new(2026, 8, 28)), base: 50)
    raw = adjusted.to_h { |day, price| [ day, day < split_on ? price / 10 : price ] }

    assert_equal [ [ split_on, Rational(1, 10) ] ], found(EtoroItem::SplitDetector.new(closes: raw, daily: adjusted))
  end

  test "a split before the daily window goes on the day of its week the raw closes jump by its ratio" do
    first_split = Date.new(2021, 7, 20)
    second_split = Date.new(2023, 6, 7)
    days = weekdays(Date.new(2021, 5, 3), Date.new(2023, 8, 31))
    adjusted = prices(days, base: 190)
    # The day's own move on the split day, and a large one later in its week.
    adjusted[first_split] = adjusted[first_split.prev_day] * BigDecimal("0.97")
    adjusted[Date.new(2021, 7, 22)] = adjusted[Date.new(2021, 7, 21)] * BigDecimal("1.08")
    factor = ->(day) { (day < first_split ? 4 : 1) * (day < second_split ? 10 : 1) }
    raw = adjusted.to_h { |day, price| [ day, price * factor.call(day) ] }
    window_start = Date.new(2022, 9, 1)
    daily = adjusted.select { |day, _| day >= window_start }
    weekly = weekly_closes(adjusted.reject { |day, _| day >= window_start })

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: daily, weekly: weekly)

    assert_equal [ [ first_split, Rational(4) ], [ second_split, Rational(10) ] ], found(detector)
  end

  test "reverse splits of any whole ratio and bonus issues are splits within the daily window" do
    switch = Date.new(2026, 7, 15)
    adjusted = prices(weekdays(Date.new(2026, 3, 2), Date.new(2026, 10, 23)), base: 50)

    [ Rational(1, 35), Rational(1, 200), Rational(1, 9), Rational(21, 20), Rational(11, 10) ].each do |ratio|
      raw = adjusted.to_h { |day, price| [ day, day < switch ? (price * ratio.numerator / ratio.denominator).round(4) : price ] }

      detector = EtoroItem::SplitDetector.new(closes: raw, daily: adjusted)

      assert_equal [ [ switch, ratio ] ], found(detector), "a #{ratio} split"
      assert_empty detector.mismatches, "a #{ratio} split"
    end
  end

  test "a split before the daily window goes on the day that moves by its ratio, not on a larger move the same way" do
    split_on = Date.new(2021, 3, 11)
    adjusted = prices(weekdays(Date.new(2021, 1, 4), Date.new(2021, 6, 30)), base: 300)
    # A 36% fall on the Monday of its week, and a 1% rise on the day itself.
    adjusted.each_key { |day| adjusted[day] *= BigDecimal("0.64") if day >= Date.new(2021, 3, 8) }
    adjusted[split_on] = adjusted[split_on.prev_day] * BigDecimal("1.01")
    raw = adjusted.to_h { |day, price| [ day, day < split_on ? price * 3 / 2 : price ] }

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: {}, weekly: weekly_closes(adjusted))

    assert_equal [ [ split_on, Rational(3, 2) ] ], found(detector)
  end

  test "a large move in the week of a split before the daily window is not taken for a second split" do
    split_on = Date.new(2021, 3, 10)
    adjusted = prices(weekdays(Date.new(2021, 1, 4), Date.new(2021, 6, 30)), base: 300)
    # Halved on the Monday of its week, and a 2% rise on the day itself.
    adjusted.each_key { |day| adjusted[day] /= 2 if day >= Date.new(2021, 3, 8) }
    adjusted[split_on] = adjusted[split_on.prev_day] * BigDecimal("1.02")
    raw = adjusted.to_h { |day, price| [ day, day < split_on ? price * 4 : price ] }

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: {}, weekly: weekly_closes(adjusted))

    assert_equal [ [ split_on, Rational(4) ] ], found(detector)
  end

  test "two splits in one week before the daily window go on their own days" do
    first_split = Date.new(2021, 3, 9)
    second_split = Date.new(2021, 3, 11)
    adjusted = prices(weekdays(Date.new(2021, 1, 4), Date.new(2021, 6, 30)), base: 300)
    raw = adjusted.to_h { |day, price| [ day, price * (day < first_split ? 2 : 1) * (day < second_split ? 3 : 1) ] }

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: {}, weekly: weekly_closes(adjusted))

    assert_equal [ [ first_split, Rational(2) ], [ second_split, Rational(3) ] ], found(detector)
  end

  test "a week compared on a day missing from the raw closes is not taken for a split" do
    days = weekdays(Date.new(2021, 5, 3), Date.new(2021, 9, 30))
    adjusted = prices(days, base: 180)
    raw = adjusted.to_h { |day, price| [ day, price * 4 ] }
    # eToro's raw series lacks a Friday its weekly close is taken on.
    raw.delete(Date.new(2021, 7, 16))
    adjusted[Date.new(2021, 7, 16)] = adjusted[Date.new(2021, 7, 15)] * BigDecimal("0.96")

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: {}, weekly: weekly_closes(adjusted))

    assert_empty detector.splits
    assert_empty detector.mismatches
  end

  test "rounding in the adjusted closes is not a split" do
    days = weekdays(Date.new(2026, 1, 5), Date.new(2026, 8, 28))
    raw = prices(days, base: 1).to_h { |day, price| [ day, price / 4 + BigDecimal("0.00003") * (day.jd % 3) ] }
    rounded = raw.transform_values { |price| price.round(4) }

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: rounded)

    assert_empty detector.splits
    assert_empty detector.mismatches
  end

  test "a dividend payer's raw and adjusted closes stay one to one across its ex-dividend day" do
    days = weekdays(Date.new(2026, 8, 3), Date.new(2026, 10, 23))
    raw = prices(days, base: 70)
    ex_dividend = Date.new(2026, 9, 15)
    raw[ex_dividend] = raw[ex_dividend.prev_day] - BigDecimal("0.51")

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: raw.dup)

    assert_empty detector.splits
    assert_empty detector.mismatches
  end

  test "a change of basis that matches no split ratio is reported, not applied" do
    changed_on = Date.new(2026, 7, 1)
    adjusted = prices(weekdays(Date.new(2026, 5, 4), Date.new(2026, 8, 28)))
    raw = adjusted.to_h { |day, price| [ day, day < changed_on ? price * BigDecimal("1.37") : price ] }

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: adjusted)

    assert_empty detector.splits
    assert_equal [ changed_on ], detector.mismatches.map(&:date)
    assert_in_delta 1.37, detector.mismatches.first.ratio.to_f, 0.001
  end

  test "the newest day alone off the basis by a bonus issue's ratio waits for a day after it" do
    days = weekdays(Date.new(2026, 8, 3), Date.new(2026, 10, 16))
    raw = prices(days)
    adjusted = raw.dup
    adjusted[days.last] = (adjusted[days.last] * BigDecimal("1.05")).round(4)

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: adjusted)

    assert_empty detector.splits
    assert_empty detector.mismatches
    assert_equal days[-2], detector.compared_through
  end

  test "a bonus issue on the newest day is found when the raw closes jump with it" do
    days = weekdays(Date.new(2026, 8, 3), Date.new(2026, 10, 16))
    adjusted = prices(days)
    raw = adjusted.to_h { |day, price| [ day, day < days.last ? price * 4 / 3 : price ] }

    assert_empty found(EtoroItem::SplitDetector.new(closes: raw, daily: adjusted))
    assert_equal [ [ days.last, Rational(4, 3) ] ], found(EtoroItem::SplitDetector.new(closes: raw, daily: adjusted, jumps: [ days.last ]))
  end

  test "a split on the newest day by a whole ratio is found" do
    days = weekdays(Date.new(2026, 8, 3), Date.new(2026, 10, 16))
    adjusted = prices(days)
    raw = adjusted.to_h { |day, price| [ day, day < days.last ? price * 2 : price ] }

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: adjusted)

    assert_equal [ [ days.last, Rational(2) ] ], found(detector)
    assert_equal days.last, detector.compared_through
  end

  test "names no day compared without daily split-adjusted closes" do
    days = weekdays(Date.new(2026, 8, 3), Date.new(2026, 10, 16))

    assert_nil EtoroItem::SplitDetector.new(closes: prices(days), daily: {}).compared_through
  end

  test "one bad day in one series is not a split and its reversal" do
    adjusted = prices(weekdays(Date.new(2026, 5, 4), Date.new(2026, 8, 28)))
    raw = adjusted.dup
    adjusted[Date.new(2026, 6, 17)] = adjusted[Date.new(2026, 6, 17)] / 10

    detector = EtoroItem::SplitDetector.new(closes: raw, daily: adjusted)

    assert_empty detector.splits
    assert_empty detector.mismatches
  end

  private

    def weekdays(from, to)
      (from..to).select(&:on_weekday?)
    end

    # Round prices that move a little from day to day.
    def prices(days, base: 100)
      days.to_h { |day| [ day, BigDecimal(base + day.jd % 5) ] }
    end

    # eToro's weekly candles, keyed by the Monday of each week, each closing
    # at the close of the last trading day of its week.
    def weekly_closes(daily)
      daily.group_by { |day, _| day.beginning_of_week }.transform_values { |days| days.max_by(&:first).last }
    end

    def found(detector)
      detector.splits.map { |split| [ split.date, split.ratio ] }
    end
end
