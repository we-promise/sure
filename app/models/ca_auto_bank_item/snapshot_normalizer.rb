class CaAutoBankItem::SnapshotNormalizer
  AccountData = Data.define(:uid, :report_uid, :kind, :name, :balance, :rate, :effective_date, :maturity_date, :metadata)
  Result = Data.define(:identity, :generation, :observed_at, :date, :accounts, :report_uids)

  def normalize(snapshot)
    raise Provider::CaAutoBank::Error.new(:invalid_snapshot) unless snapshot.is_a?(Provider::CaAutoBank::Snapshot)
    raise Provider::CaAutoBank::Error.new(:invalid_snapshot) unless snapshot.observed_at.is_a?(Time) && snapshot.observed_at <= 5.minutes.from_now
    raise Provider::CaAutoBank::Error.new(:incomplete_snapshot) unless snapshot.reports.is_a?(Array) && snapshot.reports.present? && snapshot.reports.size <= Provider::CaAutoBank::MAX_REPORTS

    accounts = []
    report_uids = []
    snapshot.reports.each do |bundle|
      scope = bundle.fetch("report")
      scope_values = %w[service branch accountNumber].map { |key| scope.fetch(key) }
      invalid! unless scope_values.all? { |value| value.is_a?(Integer) && value >= 0 }
      invalid! unless bundle.fetch("contract").fetch("accountNumber") == scope.fetch("accountNumber")

      report_uid = Digest::SHA256.hexdigest(JSON.generate(scope_values))
      invalid! if report_uids.include?(report_uid)
      report_uids << report_uid
      overview = bundle.fetch("overview")
      deposits = bundle.fetch("deposits")
      invalid! unless deposits.is_a?(Array) && deposits.size <= Provider::CaAutoBank::MAX_DEPOSITS

      cash = decimal!(overview.fetch("availableBalance"))
      restricted = decimal!(overview.fetch("restrictedBalance"))
      accrued = decimal!(overview.fetch("totalAccruedNetReturn"))
      summaries = overview.fetch("accrualOperations")
      invalid! unless summaries.is_a?(Array) && summaries.size == deposits.size
      expected_summaries = []
      principal_sum = BigDecimal("0")
      net_return_sum = BigDecimal("0")

      accounts << AccountData.new(uid: "libero:#{report_uid}", report_uid: report_uid, kind: "libero",
        name: "CA Auto Bank Libero", balance: cash, rate: nil, effective_date: nil, maturity_date: nil,
        metadata: { "source" => "availableBalance", "history_imported" => false })

      deposits.each do |deposit|
        summary = deposit.fetch("summary")
        details = deposit.fetch("details")
        invalid! unless summary.fetch("status") == "ACTIVE" && details.fetch("status") == "ACTIVE"
        operation = summary.fetch("operationNumber")
        invalid! unless operation.is_a?(Integer) && operation >= 0
        principal = decimal!(summary.fetch("amount"))
        invalid! unless principal.positive? && decimal!(details.fetch("amount")) == principal
        rate = decimal!(summary.fetch("rate"), maximum: 100)
        invalid! unless decimal!(details.fetch("operationRate"), maximum: 100) == rate
        effective = date!(summary.fetch("effectiveDate"))
        maturity = date!(summary.fetch("maturityDate"))
        invalid! unless effective <= maturity && date!(details.fetch("effectiveDate")) == effective && date!(details.fetch("maturityDate")) == maturity

        expected_summaries << [ principal, rate, effective, maturity ]
        principal_sum += principal
        uid = "deposit:#{Digest::SHA256.hexdigest("#{report_uid}:#{operation}")}"
        invalid! if accounts.any? { |account| account.uid == uid }
        accounts << AccountData.new(uid: uid, report_uid: report_uid, kind: "time_deposit",
          name: "CA Auto Bank Tempo · #{maturity.iso8601}", balance: principal, rate: rate,
          effective_date: effective, maturity_date: maturity, metadata: {
            "status" => "ACTIVE",
            "reported_interest" => decimal!(details.fetch("interests")).to_s("F"),
            "early_withdrawable" => details["earlyWithdrawable"] == true,
            "history_imported" => false, "value_basis" => "principal"
          })
      end

      actual_summaries = summaries.map do |summary|
        net_return_sum += decimal!(summary.fetch("netReturn"))
        [ decimal!(summary.fetch("amount")), decimal!(summary.fetch("rate"), maximum: 100),
          date!(summary.fetch("effectiveDate")), date!(summary.fetch("maturityDate")) ]
      end
      invalid! unless actual_summaries.tally == expected_summaries.tally
      invalid! unless principal_sum == restricted && net_return_sum == accrued
    end

    Result.new(identity: snapshot.identity, generation: snapshot.generation, observed_at: snapshot.observed_at,
      date: snapshot.observed_at.in_time_zone("Europe/Rome").to_date, accounts: accounts, report_uids: report_uids)
  rescue KeyError, TypeError, NoMethodError, ArgumentError
    raise Provider::CaAutoBank::Error.new(:invalid_snapshot), cause: nil
  end

  private

    def invalid!
      raise Provider::CaAutoBank::Error.new(:incomplete_snapshot)
    end

    def decimal!(value, maximum: BigDecimal("999999999999999"))
      text = value.to_s
      invalid! unless text.bytesize <= 40 && /\A\d+(?:\.\d+)?\z/.match?(text)

      parsed = BigDecimal(text)
      invalid! unless parsed.finite? && parsed >= 0 && parsed <= maximum

      parsed
    end

    def date!(value)
      invalid! unless value.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(value)

      Date.iso8601(value)
    end
end
