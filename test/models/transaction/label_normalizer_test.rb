require "test_helper"

class Transaction::LabelNormalizerTest < ActiveSupport::TestCase
  ENTRY_DATE = Date.new(2026, 9, 5)

  def normalize(raw, on: ENTRY_DATE, region: nil)
    Transaction::LabelNormalizer.normalize(raw, on: on, region: region)
  end

  test "strips a card prefix and the embedded operation date" do
    result = normalize("CB 02/09 CARREFOUR MARKET")

    assert_equal "CARREFOUR MARKET", result.name
    assert_equal "card", result.rail
    assert_equal Date.new(2026, 9, 2), result.operation_date
  end

  test "strips a SEPA direct debit prefix" do
    result = normalize("PRLV SEPA AMZ PRIME")

    assert_equal "AMZ PRIME", result.name
    assert_equal "direct_debit", result.rail
  end

  test "unwraps a payment aggregator to the real merchant" do
    result = normalize("CB PAYPAL *XYZ")

    assert_equal "XYZ", result.name
    assert_equal "card", result.rail
  end

  test "strips a SEPA transfer prefix in both phrasings" do
    assert_equal "XYZ", normalize("VIR SEPA XYZ").name
    assert_equal "XYZ", normalize("VIREMENT DE XYZ").name
    assert_equal "transfer", normalize("VIR SEPA XYZ").rail
  end

  test "strips a cash withdrawal prefix" do
    result = normalize("RETRAIT DAB 02/09 PARIS OPERA")

    assert_equal "PARIS OPERA", result.name
    assert_equal "withdrawal", result.rail
  end

  test "recognises bank fees" do
    assert_equal "fee", normalize("COMMISSION D INTERVENTION").rail
    assert_equal "fee", normalize("FRAIS TENUE DE COMPTE").rail
    assert_equal "TENUE DE COMPTE", normalize("FRAIS TENUE DE COMPTE").name
  end

  test "keeps the original label when nothing meaningful survives" do
    result = normalize("CHEQUE N 1234567")

    assert_equal "CHEQUE N 1234567", result.name
    assert_equal "cheque", result.rail
  end

  test "resolves a year-less date to the previous year across New Year" do
    result = normalize("CB 30/12 FNAC", on: Date.new(2026, 1, 3))

    assert_equal Date.new(2025, 12, 30), result.operation_date
    assert_equal "FNAC", result.name
  end

  test "reads an explicit year when the label carries one" do
    assert_equal Date.new(2025, 9, 2), normalize("FACTURE CARTE DU 020925 SNCF").operation_date
    assert_equal "SNCF", normalize("FACTURE CARTE DU 020925 SNCF").name
  end

  # Banks are not consistent about the case of the DU token, and the compact
  # variant below already matched case-insensitively. Leaving the slashed one
  # case-sensitive split "CB du 02/09 CARREFOUR" into a payee literally called
  # "du CARREFOUR", away from the same merchant billed in upper case.
  test "strips the DU token whatever its case" do
    %w[du DU Du dU].each do |token|
      result = normalize("CB #{token} 02/09 CARREFOUR")

      assert_equal "CARREFOUR", result.name, "#{token} was not stripped"
      assert_equal Date.new(2026, 9, 2), result.operation_date
    end
  end

  test "returns no operation date when the entry date is unknown" do
    result = normalize("CB 02/09 CARREFOUR", on: nil)

    assert_nil result.operation_date
    assert_equal "CARREFOUR", result.name
  end

  test "leaves a merchant name that merely starts with a prefix letter sequence alone" do
    assert_equal "VIRGIN MEGASTORE", normalize("VIRGIN MEGASTORE").name
    assert_nil normalize("VIRGIN MEGASTORE").rail
    assert_equal "CBD SHOP", normalize("CBD SHOP").name
  end

  test "leaves plain user-entered text untouched" do
    result = normalize("Groceries")

    assert_equal "Groceries", result.name
    assert_nil result.rail
    assert_nil result.operation_date
  end

  test "drops trailing card and contract numbers" do
    assert_equal "MONOPRIX", normalize("CB 02/09 MONOPRIX CARTE 1234567").name
    assert_equal "EDF", normalize("PRLV SEPA EDF REF 998877665544").name
  end

  test "reports whether it changed anything" do
    assert normalize("CB 02/09 CARREFOUR").normalized?("CB 02/09 CARREFOUR")
    assert_not normalize("Groceries").normalized?("Groceries")
  end

  test "handles a blank label without raising" do
    assert_equal "", normalize("").name
    assert_equal "", normalize(nil).name
  end

  test "recognises a refund, which the domain has no other way to express" do
    assert_equal "refund", normalize("AVOIR AMAZON EU").rail
    assert_equal "AMAZON EU", normalize("AVOIR AMAZON EU").name
    assert_equal "refund", normalize("REMBOURSEMENT SNCF").rail
    assert_equal "refund", normalize("ANNULATION CB FNAC").rail
  end

  # A refund that keeps its nested card marker groups as a different payee from
  # the purchase it reverses, which defeats the whole point of normalizing.
  test "a refund reduces to the same merchant as the purchase it reverses" do
    purchase = normalize("CB FNAC")

    assert_equal purchase.name, normalize("ANNULATION CB FNAC").name
    assert_equal purchase.name, normalize("REMBOURSEMENT CARTE FNAC").name
    assert_equal "refund", normalize("ANNULATION CB FNAC").rail
    assert_equal "refund", normalize("REMBOURSEMENT CARTE FNAC").rail
  end

  test "reads a loan instalment as a loan payment, not as a refund" do
    assert_equal "loan_payment", normalize("REMB PRET IMMO").rail
    assert_equal "loan_payment", normalize("ECHEANCE PRET ETUDIANT").rail
    assert_equal "PRET ETUDIANT", normalize("ECHEANCE PRET ETUDIANT").name
  end

  # The packs below are the answer to the review note that this class was
  # French-bank specific. Every pack is always active, so these all pass without
  # anyone configuring a locale.

  test "reads a US card label, whose marker also settles the month-first date" do
    result = normalize("PURCHASE AUTHORIZED ON 09/02 TRADER JOE S #123 SAN DIEGO CA")

    assert_equal "TRADER JOE S #123 SAN DIEGO CA", result.name
    assert_equal "card", result.rail
    assert_equal Date.new(2026, 9, 2), result.operation_date
  end

  # Same six digits, opposite meaning. The marker says which bank wrote the
  # label, which is far better evidence than any family setting: a French
  # self-hoster running the app in English is the common case.
  test "the same digits read differently depending on the marker that preceded them" do
    assert_equal Date.new(2026, 9, 2), normalize("PURCHASE AUTHORIZED ON 09/02 TRADER JOE S").operation_date
    assert_equal Date.new(2026, 2, 9), normalize("CB 09/02 CARREFOUR").operation_date
  end

  # A number above 12 cannot be a month, so it settles the reading on its own.
  # This is what keeps a misconfigured region from ever producing a wrong date
  # for anything but a genuinely ambiguous one.
  test "a day above twelve overrides the region convention" do
    assert_equal Date.new(2025, 12, 27), normalize("PURCHASE AUTHORIZED ON 27/12 TRADER JOE S").operation_date
    assert_equal Date.new(2025, 12, 27), normalize("CB 27/12 CARREFOUR").operation_date
  end

  # With no marker there is nothing in the label to go on, so the caller's
  # country hint decides. Both call sites pass families.country.
  test "falls back to the region hint when no marker identifies the bank" do
    assert_equal Date.new(2026, 2, 9), normalize("02/09 SOME SHOP LTD", region: "US").operation_date
    assert_equal Date.new(2026, 9, 2), normalize("02/09 SOME SHOP LTD", region: "FR").operation_date
    assert_equal Date.new(2026, 9, 2), normalize("02/09 SOME SHOP LTD").operation_date
  end

  test "reads UK, German, Spanish, Italian, Dutch and Portuguese markers" do
    {
      "Card Payment to TESCO STORES 3324" => [ "TESCO STORES 3324", "card" ],
      "DIRECT DEBIT PAYMENT TO VODAFONE LTD" => [ "VODAFONE LTD", "direct_debit" ],
      "KARTENZAHLUNG REWE MARKT GMBH" => [ "REWE MARKT GMBH", "card" ],
      "DAUERAUFTRAG MIETE WOHNUNG" => [ "MIETE WOHNUNG", "transfer" ],
      "COMPRA CON TARJETA MERCADONA VALENCIA" => [ "MERCADONA VALENCIA", "card" ],
      "REINTEGRO CAJERO BBVA" => [ "BBVA", "withdrawal" ],
      "PAGAMENTO POS ESSELUNGA MILANO" => [ "ESSELUNGA MILANO", "card" ],
      "RATA MUTUO INTESA SANPAOLO" => [ "INTESA SANPAOLO", "loan_payment" ],
      "SEPA INCASSO ALGEMEEN DOORLOPEND ZIGGO BV" => [ "ZIGGO BV", "direct_debit" ],
      "GELDAUTOMAAT ING AMSTERDAM" => [ "ING AMSTERDAM", "withdrawal" ],
      "COMPRA COM CARTAO CONTINENTE LISBOA" => [ "CONTINENTE LISBOA", "card" ],
      "PIX ENVIADO PADARIA CENTRAL" => [ "PADARIA CENTRAL", "transfer" ]
    }.each do |raw, (name, rail)|
      result = normalize(raw)

      assert_equal name, result.name, raw
      assert_equal rail, result.rail, raw
    end
  end

  # Every marker is tried against every label whatever country wrote it, so a
  # token only earns its place if it cannot begin a real merchant name once
  # anchored and bounded. These are the names the audit said were at risk; each
  # one must come through untouched, with no rail guessed for it either.
  test "leaves merchants that begin with another region's marker alone" do
    [
      "KAUFLAND SAGT DANKE",      # bare KAUF would gut Germany's largest chain
      "GALERIA KAUFHOF",
      "ELV ELEKTRONIK AG",
      "POSTBANK FILIALE",
      "IDEAL STANDARD BENELUX",
      "INCASSOBUREAU FIDITON",
      "CARTA MUSICA SARDA",
      "CHECKERS DRIVE IN",
      "CHECK INTO CASH 4432",
      "REFUNDO TAX",
      "TRANSFERWISE LTD",
      "DEBENHAMS OXFORD ST",
      "VISTAPRINT NL",
      "VIRGIN MEGASTORE",
      "CBD SHOP"
    ].each do |raw|
      result = normalize(raw)

      assert_equal raw, result.name
      assert_nil result.rail, "#{raw} was given a rail it does not have"
    end
  end

  # A connector must be followed by whitespace. Without that rule "AT" matched
  # inside "AT&T" and left a merchant called "T".
  test "swallows the connector between a marker and the merchant" do
    assert_equal "TESCO STORES", normalize("Card Payment to TESCO STORES").name
    assert_equal "HSBC HIGH ST", normalize("Cash Withdrawal at HSBC HIGH ST").name
    assert_equal "JUAN PEREZ", normalize("TRANSFERENCIA RECIBIDA DE JUAN PEREZ").name
    assert_equal "MARIO ROSSI", normalize("BONIFICO SEPA A FAVORE DI MARIO ROSSI").name
    assert_equal "AT&T MOBILITY", normalize("AT&T MOBILITY").name
  end

  # ON is read only when a date follows it, so Barclays' "ON 03 SEP" resolves
  # while the shoe brand On Running keeps its name.
  test "reads an alphabetic month, and only treats ON as one when a date follows" do
    result = normalize("POS 5250 27DEC24 TESCO STORE 3243 LONDON GB")

    assert_equal "TESCO STORE 3243 LONDON GB", result.name
    assert_equal Date.new(2024, 12, 27), result.operation_date
    assert_equal Date.new(2026, 9, 3), normalize("Card Payment on 03 SEP JOHN LEWIS").operation_date
    assert_equal "ON RUNNING", normalize("CB ON RUNNING").name
  end

  # The terminal id changes on every visit, so leaving it in splits one payee
  # into dozens. It is only stripped at the front and only after a marker was
  # consumed: a store number further along is part of the name.
  test "drops a terminal id after the marker but keeps a store number in the name" do
    assert_equal "TIM HORTONS #4521", normalize("Interac purchase - 1234 TIM HORTONS #4521").name
    assert_equal "TESCO STORE 3243", normalize("Card Payment to TESCO STORE 3243").name
  end

  # SEPA structured references and US ACH descriptor fields trail the
  # counterparty, so everything from the first tag onward is the payment system
  # talking to itself.
  test "truncates at a structured reference block" do
    assert_equal "VODAFONE GMBH", normalize("SEPA-LASTSCHRIFT VODAFONE GMBH EREF+12345 MREF+ABC").name
    assert_equal "AMERICAN EXPRESS", normalize("AMERICAN EXPRESS DES:ACH PMT INDN: J SMITH CO ID: XXX123 PPD").name
    assert_equal "SPARKASSE", normalize("BARGELDAUSZAHLUNG GA NR00012345 SPARKASSE").name
  end

  test "a refund reduces to the purchase it reverses in every region" do
    assert_equal normalize("Card Payment to ASOS.COM LTD").name, normalize("Refund Card Payment to ASOS.COM LTD").name
    assert_equal normalize("KARTENZAHLUNG AMAZON").name, normalize("RUECKLASTSCHRIFT KARTENZAHLUNG AMAZON").name
    assert_equal "refund", normalize("RUECKLASTSCHRIFT KARTENZAHLUNG AMAZON").rail
    assert_equal "refund", normalize("DEVOLUCION ZARA ESPANA").rail
  end

  # Rail order encodes real ambiguities, and getting it wrong is silent: "ATM
  # FEE" would read as cash taken out at a merchant called FEE.
  test "prefers the rail that resolves an ambiguous marker" do
    assert_equal "fee", normalize("ATM OPERATOR FEE CARDTRONICS").rail
    assert_equal "CARDTRONICS", normalize("ATM OPERATOR FEE CARDTRONICS").name
    assert_equal "withdrawal", normalize("ATM WITHDRAWAL 100 MAIN ST").rail
    assert_equal "loan_payment", normalize("LOAN REPAYMENT HALIFAX PLC").rail
  end

  test "unwraps the aggregators that put the merchant after a star" do
    assert_equal "SWEETGREEN 123", normalize("TST* SWEETGREEN 123").name
    assert_equal "EATS", normalize("UBER *EATS").name
    assert_equal "DOORDASH", normalize("DD *DOORDASH").name
    assert_equal "card", normalize("TST* SWEETGREEN 123").rail
  end
end
