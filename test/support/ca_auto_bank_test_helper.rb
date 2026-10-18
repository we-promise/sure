module CaAutoBankTestHelper
  def ca_token(expires_at: 1.hour.from_now)
    [ { alg: "ES512", typ: "JWT" }, { exp: expires_at.to_i, iat: Time.current.to_i, sub: "synthetic-user" } ]
      .map { |value| Base64.urlsafe_encode64(JSON.generate(value), padding: false) }.join(".") + ".synthetic-signature"
  end

  def ca_connected_item(owner: users(:family_admin))
    CaAutoBankItem.create!(family: owner.family, owner: owner, authentication_token: ca_token,
      account_identity: "synthetic-partner", request_session_id: "synthetic-session", session_expires_at: 1.hour.from_now,
      connection_generation: 1, status: :connected)
  end

  def ca_snapshot(item, cash: 125, deposits: [ 1000, 2000 ], observed_at: Time.current)
    rows = deposits.each_with_index.map do |amount, index|
      {
        "summary" => { "operationNumber" => index + 1, "status" => "ACTIVE", "amount" => amount, "rate" => 3.5,
          "effectiveDate" => "2026-01-01", "maturityDate" => "2028-01-01", "timeDepositToken" => "private-deposit-#{index}" },
        "details" => { "status" => "ACTIVE", "amount" => amount, "operationRate" => 3.5,
          "effectiveDate" => "2026-01-01", "maturityDate" => "2028-01-01", "interests" => amount / 100,
          "earlyWithdrawable" => true }
      }
    end
    overview = { "availableBalance" => cash, "restrictedBalance" => deposits.sum,
      "totalAccruedNetReturn" => deposits.sum / 100,
      "accrualOperations" => deposits.map { |amount| { "amount" => amount, "rate" => 3.5,
        "effectiveDate" => "2026-01-01", "maturityDate" => "2028-01-01", "netReturn" => amount / 100 } } }
    Provider::CaAutoBank::Snapshot.new(identity: item.account_identity, generation: item.connection_generation,
      observed_at: observed_at, reports: [ {
        "report" => { "service" => 1, "branch" => 2, "accountNumber" => 12345 },
        "contract" => { "accountNumber" => 12345, "accountHolderName" => "Synthetic Owner" },
        "overview" => overview, "deposits" => rows
      } ])
  end
end
