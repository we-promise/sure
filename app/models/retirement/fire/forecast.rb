module Retirement
  module Fire
    # Deterministic annual stepper for a single retirement plan, in real
    # (today's-money) terms: the portfolio grows at the real return, the
    # spending target and pension incomes are held in today's money, so no
    # inflation parameter is needed. v2 escalates to a Sidekiq Monte Carlo
    # over historical returns behind the same call interface.
    #
    #   Retirement::Fire::Forecast.new(inputs).call # => ForecastResult
    class Forecast
      def initialize(inputs)
        @i = inputs
      end

      def call
        glide, income_by_year, lasts_to, depleted = run_glide(savings_until: i.retire_age)

        ForecastResult.new(
          glide: glide,
          income_by_year: income_by_year,
          money_lasts_to_age: lasts_to,
          terminal_value: glide.last.last,
          coast_age: coast_age,
          feasible: !depleted,
          warnings: build_warnings(depleted)
        )
      end

      private
        attr_reader :i

        def rate
          1 + i.real_return.to_d
        end

        # Annual spending target at a given age = base anchor plus any
        # adjustments whose age window covers it (signed; today's money).
        def annual_target_at(age)
          base = i.annual_target_spend.to_d
          extra = Array(i.target_adjustments).select { |adj| adj.applicable_at?(age) }
                                             .sum { |adj| adj.annual_amount.to_d }
          base + extra
        end

        def run_glide(savings_until:)
          portfolio = i.starting_portfolio.to_d
          glide = [ [ i.current_age, portfolio.round ] ]
          income_by_year = []
          lasts_to = i.terminal_age
          depleted = false

          (i.current_age...i.terminal_age).each do |age|
            if age < i.retire_age
              contribution = age < savings_until ? i.annual_savings.to_d : 0.to_d
              portfolio = (portfolio * rate) + contribution
            else
              gross = { state: 0.to_d, workplace: 0.to_d, other: 0.to_d }
              lump = 0.to_d
              i.payouts.each do |payout|
                contribution = payout.contribute_at(age)
                net = Retirement::Tax::StaticRate.net_at(contribution[:income], payout.tax_treatment, retire_year: i.retire_year)
                bucket = gross.key?(payout.kind.to_sym) ? payout.kind.to_sym : :other
                gross[bucket] += net
                lump += contribution[:portfolio_delta]
              end

              total_income = gross.values.sum
              drawdown_needed = [ annual_target_at(age) - total_income, 0.to_d ].max
              portfolio = (portfolio * rate) + lump - drawdown_needed

              shortfall = 0.to_d
              if portfolio.negative?
                shortfall = -portfolio
                portfolio = 0.to_d
                unless depleted
                  lasts_to = age
                  depleted = true
                end
              end

              income_by_year << {
                age: age,
                state: gross[:state].round,
                workplace: gross[:workplace].round,
                other: gross[:other].round,
                drawdown: (drawdown_needed - shortfall).round,
                shortfall: shortfall.round
              }
            end

            glide << [ age + 1, portfolio.round ]
          end

          [ glide, income_by_year, lasts_to, depleted ]
        end

        # Earliest age from which contributions can stop and the portfolio
        # still reaches the minimum survivable amount by retire_age. nil if
        # saving the whole time still falls short (infeasible plan).
        def coast_age
          return @coast_age if defined?(@coast_age)

          @coast_age =
            if portfolio_at_retirement(savings_until: i.retire_age) < required_at_retirement
              nil
            else
              (i.current_age..i.retire_age).find do |candidate|
                portfolio_at_retirement(savings_until: candidate) >= required_at_retirement
              end
            end
        end

        # Bisection: smallest starting portfolio at retire_age that survives
        # drawdown to terminal_age.
        def required_at_retirement
          @required_at_retirement ||= begin
            lo = 0.to_d
            hi = [ i.annual_target_spend.to_d * 50, 1.to_d ].max
            40.times do
              mid = (lo + hi) / 2
              survives_drawdown?(mid) ? hi = mid : lo = mid
            end
            hi
          end
        end

        def survives_drawdown?(start_portfolio)
          portfolio = start_portfolio.to_d
          (i.retire_age...i.terminal_age).each do |age|
            gross = 0.to_d
            lump = 0.to_d
            i.payouts.each do |payout|
              contribution = payout.contribute_at(age)
              gross += Retirement::Tax::StaticRate.net_at(contribution[:income], payout.tax_treatment, retire_year: i.retire_year)
              lump += contribution[:portfolio_delta]
            end
            drawdown = [ annual_target_at(age) - gross, 0.to_d ].max
            portfolio = (portfolio * rate) + lump - drawdown
            return false if portfolio.negative?
          end
          true
        end

        def portfolio_at_retirement(savings_until:)
          portfolio = i.starting_portfolio.to_d
          (i.current_age...i.retire_age).each do |age|
            contribution = age < savings_until ? i.annual_savings.to_d : 0.to_d
            portfolio = (portfolio * rate) + contribution
          end
          portfolio
        end

        def build_warnings(depleted)
          warnings = []
          warnings << "depletes_before_terminal" if depleted
          warnings << "infeasible_no_coast" if coast_age.nil?
          warnings
        end
    end
  end
end
