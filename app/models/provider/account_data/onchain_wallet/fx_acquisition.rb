# Pure branching over immutable operation responses. The supplied read function
# requests one absent input through Assembly/Feeder; this class never does HTTP.
class Provider::AccountData::OnchainWallet::FxAcquisition
  def self.yahoo_policy
    { "format" => "yahoo-captured-fx/v1", "auth_generations" => 3, "refreshes_per_direction" => 1, "lookback_days" => 10 }
  end

  def initialize(options:, from:, to:, date:, read:, reference: nil)
    Provider::AccountData::OnchainWallet::FxReader.request(from: from, to: to, date: date)
    @options, @from, @to, @date, @read, @reference = options, from, to, date, read, reference
  end

  def call
    return moex_history if @options.fetch("provider") == "moex_public"
    return yahoo_history if @options.fetch("provider") == "yahoo_finance"
    captured = @read.call("fx_remote", from: @from, to: @to, date: @date.iso8601)
    Provider::AccountData::OnchainWallet::FxReader.rate(captured, from: @from, to: @to, date: @date, provider: @options.fetch("provider"))
  end

  private
    def yahoo_history
      reader = Provider::AccountData::OnchainWallet::YahooFxReader
      raise ArgumentError unless @reference && @options.fetch("acquisition_policy") == self.class.yahoo_policy
      configuration = reader.new(options: @options).configuration
      generation = 0
      session = nil
      %w[direct inverse].each do |direction|
        refreshed = false
        loop do
          unless session
            cookie, cookie_reference = yahoo_step("cookie", generation, configuration: configuration)
            if cookie["status"] == "response"
              crumb, crumb_reference = yahoo_step("crumb", generation, configuration: configuration, references: { "cookie" => cookie_reference })
              session = { "cookie" => cookie_reference, "crumb" => crumb_reference } if crumb["status"] == "response"
              disposition = crumb
            else
              disposition = cookie
            end
            unless session
              return nil unless disposition["status"] == "auth_expired" && !refreshed && generation < 2
              generation += 1
              refreshed = true
              next
            end
          end
          chart, = yahoo_step("chart", generation, configuration: configuration, direction: direction, references: session)
          refreshable = chart["status"] == "auth_expired" || (chart["status"] == "authentication_failed" && chart["http_status"] == 200)
          if refreshable && !refreshed && generation < 2
            generation += 1
            refreshed = true
            session = nil
            next
          end
          if chart["status"] == "response"
            # A valid empty series has no inverse fallback. Only an explicit
            # unavailable pair advances to the inverse direction.
            return reader.rate(chart, from: @from, to: @to, date: @date, auth_generation: generation, direction: direction)
          end
          return nil unless chart["status"] == "pair_unavailable" && direction == "direct"
          break
        end
      end
      nil
    end

    def yahoo_step(step, generation, configuration:, direction: nil, references: {})
      arguments = { step: step, from: @from, to: @to, date: @date.iso8601, auth_generation: generation, auth_refs: references }
      arguments[:direction] = direction if direction
      capture = @read.call("fx_yahoo", **arguments)
      reader = Provider::AccountData::OnchainWallet::YahooFxReader
      expected = reader.request(action: step, from: @from, to: @to, date: @date, auth_generation: generation, direction: direction)
      reader.validate_envelope!(capture, action: step, request: expected, configuration: configuration)
      [ capture, @reference.call("fx_yahoo", **arguments) ]
    rescue ArgumentError, TypeError, KeyError
      raise Provider::AccountData::InvalidResponse, "Invalid captured Yahoo FX acquisition", cause: nil
    end

    def moex_history
      reader = Provider::AccountData::OnchainWallet::MoexFxReader
      policy = reader.validate_options!(@options)
      by_date = {}
      policy.fetch("max_pages").times do |index|
        start = index * reader::PAGE_SIZE
        capture = @read.call("fx_moex_history", from: @from, to: @to, date: @date.iso8601, start: start)
        rows = reader.rows(capture, options: @options, from: @from, to: @to, date: @date, start: start)
        return nil if rows.nil? # An explicit, captured unsupported pair.
        rows.each do |row|
          day = row.fetch("date")
          if by_date.key?(day) && by_date.fetch(day) != row
            raise Provider::AccountData::InvalidResponse, "Conflicting wallet MOEX observations for one date"
          end
          by_date[day] = row
        end
        if rows.size < reader::PAGE_SIZE
          selected = by_date.values.select { |row| row["rate"] }.max_by { |row| row.fetch("date") }
          return nil unless selected
          original = BigDecimal(selected.fetch("rate"))
          inverse = capture.fetch("request").fetch("inverted")
          rate = inverse ? (BigDecimal("1") / original).round(12) : original
          return nil unless rate.positive?
          return { "rate" => rate.to_s("F"), "date" => selected.fetch("date"), "source" => "provider_response", "provider" => "moex_public",
            "policy" => reader::POLICY, "instrument" => capture.dig("request", "instrument"), "board" => "CETS",
            "field" => selected.fetch("field"), "original_rate" => original.to_s("F"), "inverted" => inverse }
        end
      end
      raise Provider::AccountData::IncompletePage, "Wallet MOEX history reached its captured page budget"
    end
end
