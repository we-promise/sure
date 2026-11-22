require "test_helper"

class AccountStatement::TextMetadataParserTest < ActiveSupport::TestCase
  def balances(result, currency: "EUR", classification: nil)
    AccountStatement::TextMetadataParser.balances_for(result.balance_readings, classification: classification, currency: currency)
  end

  # A Trade Republic statement, in the text order of a layout-preserving extractor.
  LAYOUT_TEXT = <<~TEXT
    TRADE REPUBLIC BANK GMBH, BRANCH ITALY
    MARIO ROSSI                                   DATA 01 gen 2025 - 31 dic 2025
                                                  IBAN IT00X0000000000000000001234
    ESTRATTO CONTO RIASSUNTIVO
    PRODOTTO        SALDO INIZIALE    IN ENTRATA     IN USCITA      SALDO FINALE
    Conto corrente  821,00 €          62.190,10 €    61.066,52 €    1.944,58 €
    TRANSAZIONI SUL CONTO
    01 gen 2025  Interessi  Your interest payment  0,26 €  821,26 €
  TEXT

  # Same statement with every cell on its own line, as a plain extractor emits it.
  STACKED_TEXT = <<~TEXT
    TRADE REPUBLIC BANK GMBH, BRANCH ITALY
    01 apr 2026 - 30 apr 2026
    DATA
    IBAN IT00X0000000000000000001234
    ESTRATTO CONTO RIASSUNTIVO
    PRODOTTO
    SALDO INIZIALE
    IN ENTRATA
    IN USCITA
    SALDO FINALE
    Conto corrente
    1.101,14 €
    14.514,42 €
    3.666,97 €
    11.948,59 €
  TEXT

  # A statement with the balances next to their labels and numeric dates.
  GERMAN_TEXT = <<~TEXT
    Kontoauszug Nr. 4
    Zeitraum: 01.04.2026 - 30.04.2026
    IBAN DE89 3704 0044 0532 0130 00 BIC COBADEFFXXX
    Alter Kontostand vom 31.03.2026          1.234,56 EUR
    02.04.2026  Miete                          -800,00 EUR
    15.04.2026  Gehalt                        1.565,44 EUR
    Neuer Kontostand vom 30.04.2026          2.000,00 EUR
  TEXT

  test "reads period, balances and IBAN from a summary table" do
    result = AccountStatement::TextMetadataParser.parse(LAYOUT_TEXT)

    assert_equal Date.new(2025, 1, 1), result.period_start_on
    assert_equal Date.new(2025, 12, 31), result.period_end_on
    assert_equal BigDecimal("821.00"), balances(result).opening_balance
    assert_equal BigDecimal("1944.58"), balances(result).closing_balance
    assert_equal "EUR", balances(result).currency
    assert_equal "1234", result.iban_last4
    assert_equal "summary_table", balances(result).source
  end

  test "reads a summary table whose cells are on separate lines" do
    result = AccountStatement::TextMetadataParser.parse(STACKED_TEXT)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal Date.new(2026, 4, 30), result.period_end_on
    assert_equal BigDecimal("1101.14"), balances(result).opening_balance
    assert_equal BigDecimal("11948.59"), balances(result).closing_balance
  end

  test "reads labelled balances, numeric dates and a grouped IBAN" do
    result = AccountStatement::TextMetadataParser.parse(GERMAN_TEXT)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal Date.new(2026, 4, 30), result.period_end_on
    assert_equal BigDecimal("1234.56"), balances(result).opening_balance
    assert_equal BigDecimal("2000.00"), balances(result).closing_balance
    assert_equal "EUR", balances(result).currency
    assert_equal "3000", result.iban_last4
    assert_equal "labels", balances(result).source
  end

  test "takes the period from the balance labels over a promotion's date range" do
    # Shaped like an isybank statement: no period range, the closing amount on
    # the line after its label, a column of stray digits, "Saldo.iniziale" as
    # some extractors emit it, and a promotion with its own date range.
    text = <<~TEXT
      ESTRATTO CONTO N. 002/2026
      AL 30.06.2026
            Riepilogo conto
            Saldo.iniziale al       01.04.2026                         +1.250,00           €
            Totale accrediti                                           +2.400,00            €
            Totale addebiti                                            -1.975,40            €
            Saldo del periodo                                            +424,60          €
      4
      -        Saldo finale al 30.06.2026
      0                                                                 +1.674,60 €
      2     Avvisi importanti
            Prelievi gratuiti dal 3 luglio 2026 al 30 giugno 2027
    TEXT

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal Date.new(2026, 6, 30), result.period_end_on
    assert_equal BigDecimal("1250.00"), balances(result).opening_balance
    assert_equal BigDecimal("1674.60"), balances(result).closing_balance
    assert_equal "EUR", balances(result).currency
    assert_equal "labels", balances(result).source
  end

  test "starts the period after an opening balance dated at a month end" do
    text = "Alter Kontostand vom 31.03.2026  1.234,56 EUR\nNeuer Kontostand vom 30.04.2026  2.000,00 EUR"

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal Date.new(2026, 4, 30), result.period_end_on
  end

  test "reads month-first dates and pounds" do
    text = "Statement period 1 April 2026 to 30 April 2026\nBalance brought forward £1,234.56\n" \
      "Payments in £500.00\nClosing balance £1,734.56"

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal BigDecimal("1734.56"), balances(result, currency: "GBP").closing_balance
    assert_equal "GBP", balances(result, currency: "GBP").currency

    us = AccountStatement::TextMetadataParser.parse("Statement Period: April 1, 2026 through April 30, 2026")
    assert_equal Date.new(2026, 4, 1), us.period_start_on
    assert_equal Date.new(2026, 4, 30), us.period_end_on

    iso = AccountStatement::TextMetadataParser.parse("Period 2026-04-01 to 2026-04-30")
    assert_equal Date.new(2026, 4, 30), iso.period_end_on
  end

  test "reads a dollar amount only in the statement's dollar currency" do
    text = "Statement Period: April 1, 2026 through April 30, 2026\nBeginning Balance $2,500.00\nEnding Balance $3,100.25"

    usd = balances(AccountStatement::TextMetadataParser.parse(text), currency: "USD")
    assert_equal BigDecimal("2500.00"), usd.opening_balance
    assert_equal "USD", usd.currency

    assert_nil balances(AccountStatement::TextMetadataParser.parse(text), currency: "EUR")
  end

  test "reads a period without balances from an ordinal-date statement" do
    text = <<~TEXT
      MPESA FULL STATEMENT
      Date of Statement:   13th 10 2025
      Statement Period:    01st 1 2025 - 01st 7 2025
      SUMMARY
      TRANSACTION TYPE     PAID IN       PAID OUT
      TOTAL:               127,000.00    122,757.00
    TEXT

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2025, 1, 1), result.period_start_on
    assert_equal Date.new(2025, 7, 1), result.period_end_on
    assert_nil balances(result)&.opening_balance
    assert_nil balances(result)&.closing_balance
    assert_nil balances(result)&.source
  end

  test "understands German and English month names and amount formats" do
    german = "DATUM 01 März 2026 - 31 März 2026\nANFANGSSALDO ZAHLUNGSEINGANG ZAHLUNGSAUSGANG ENDSALDO\n" \
      "Cashkonto 5.440,93 € 0,00 € 4.339,79 € 1.101,14 €"
    english = "DATE 01 Sept 2026 - 30 Sept 2026\nOPENING BALANCE MONEY IN MONEY OUT CLOSING BALANCE\n" \
      "Cash account €4,324.20 €100.00 €2,577.30 €1,846.90"

    german_result = AccountStatement::TextMetadataParser.parse(german)
    assert_equal Date.new(2026, 3, 1), german_result.period_start_on
    assert_equal BigDecimal("1101.14"), balances(german_result).closing_balance

    english_result = AccountStatement::TextMetadataParser.parse(english)
    assert_equal Date.new(2026, 9, 30), english_result.period_end_on
    assert_equal BigDecimal("4324.20"), balances(english_result).opening_balance
    assert_equal BigDecimal("1846.90"), balances(english_result).closing_balance
  end

  test "reads French statements and full month names" do
    french = "DATE 01 juil. 2026 - 31 juil. 2026\nSYNTHÈSE DU RELEVÉ DE COMPTE\n" \
      "PRODUIT SOLDE D'OUVERTURE ENTRÉE D'ARGENT SORTIE D'ARGENT SOLDE DE FERMETURE\n" \
      "Compte courant 7 099,61 € 1 250,00 € 4 025,41 € 4 324,20 €"
    german = "DATUM 01. Oktober 2025 - 31. Dezember 2025\nANFANGSSALDO\n100,00 € 50,00 € 25,00 € 125,00 €"

    french_result = AccountStatement::TextMetadataParser.parse(french)
    assert_equal Date.new(2026, 7, 1), french_result.period_start_on
    assert_equal Date.new(2026, 7, 31), french_result.period_end_on
    assert_equal BigDecimal("7099.61"), balances(french_result).opening_balance
    assert_equal BigDecimal("4324.20"), balances(french_result).closing_balance

    german_result = AccountStatement::TextMetadataParser.parse(german)
    assert_equal Date.new(2025, 10, 1), german_result.period_start_on
    assert_equal Date.new(2025, 12, 31), german_result.period_end_on
    assert_equal BigDecimal("125.00"), balances(german_result).closing_balance
  end

  test "reads Spanish and Dutch long month names" do
    spanish = "FECHA 01 septiembre 2026 - 30 septiembre 2026\nSALDO INICIAL\n10,00 € 5,00 € 1,00 € 14,00 €"
    dutch = "DATUM 01 maart 2026 - 31 maart 2026\nBEGINSALDO\n10,00 € 5,00 € 1,00 € 14,00 €"

    spanish_result = AccountStatement::TextMetadataParser.parse(spanish)
    assert_equal Date.new(2026, 9, 1), spanish_result.period_start_on
    assert_equal Date.new(2026, 9, 30), spanish_result.period_end_on

    dutch_result = AccountStatement::TextMetadataParser.parse(dutch)
    assert_equal Date.new(2026, 3, 1), dutch_result.period_start_on
    assert_equal Date.new(2026, 3, 31), dutch_result.period_end_on
    assert_equal BigDecimal("14.00"), balances(dutch_result).closing_balance
  end

  test "keeps the sign of negative balances in either currency position" do
    prefix = "DATE 01 Aug 2026 - 31 Aug 2026\nOPENING BALANCE MONEY IN MONEY OUT CLOSING BALANCE\n" \
      "Cash account -€12.34 €100.00 €50.00 €37.66"
    inner = prefix.sub("-€12.34", "€-12.34")
    suffix = "DATA 01 ago 2026 - 31 ago 2026\nSALDO INIZIALE\n10,00 € 0,00 € 22,34 € -12,34 €"

    [ prefix, inner ].each do |text|
      result = AccountStatement::TextMetadataParser.parse(text)
      assert_equal BigDecimal("-12.34"), balances(result).opening_balance
      assert_equal BigDecimal("37.66"), balances(result).closing_balance
    end

    assert_equal BigDecimal("-12.34"), balances(AccountStatement::TextMetadataParser.parse(suffix)).closing_balance
  end

  test "drops balances that do not add up" do
    text = LAYOUT_TEXT.sub("1.944,58 €", "1.999,99 €")

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2025, 1, 1), result.period_start_on
    assert_nil balances(result)&.opening_balance
    assert_nil balances(result)&.closing_balance
    assert_nil balances(result)&.currency
  end

  test "drops labelled balances in different currencies" do
    text = GERMAN_TEXT.sub("2.000,00 EUR", "2.000,00 USD")

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_nil balances(result)&.opening_balance
    assert_nil balances(result)&.closing_balance
  end

  # A credit card statement whose closing balance is in credit ("CR").
  CARD_LABELS_TEXT = <<~TEXT
    Statement period 12 Apr 2024 - 15 May 2024
    Opening balance $1,066.47
    Closing balance $435.88 CR
  TEXT

  CARD_SUMMARY_TEXT = <<~TEXT
    Statement period 12 Apr 2024 - 15 May 2024
    Opening balance    Debits     Credits      Closing balance
    $1,066.47          $0.00      $1,502.35    $435.88 CR
  TEXT

  def card_balances(text, classification:, currency: "AUD")
    balances(AccountStatement::TextMetadataParser.parse(text), currency: currency, classification: classification)
  end

  test "reads a CR balance on a liability as in credit" do
    result = card_balances(CARD_LABELS_TEXT, classification: "liability")

    assert_equal BigDecimal("1066.47"), result.opening_balance
    assert_equal BigDecimal("-435.88"), result.closing_balance
    assert_equal "labels", result.source
  end

  test "keeps a summary table whose CR closing balance only adds up as a credit" do
    result = card_balances(CARD_SUMMARY_TEXT, classification: "liability")

    assert_equal "summary_table", result.source
    assert_equal BigDecimal("1066.47"), result.opening_balance
    assert_equal BigDecimal("-435.88"), result.closing_balance
  end

  test "returns the readings as printed and the kinds of account the table adds up as" do
    readings = AccountStatement::TextMetadataParser.parse(CARD_SUMMARY_TEXT).balance_readings

    assert_equal(
      {
        "opening_balance" => { "amount" => "1066.47", "side" => nil, "currency" => "$" },
        "closing_balance" => { "amount" => "435.88", "side" => "credit", "currency" => "$" },
        "adds_up_as" => [ "liability" ]
      },
      readings["summary_table"]
    )
  end

  test "keeps a CR summary table without an account, unsigned" do
    result = card_balances(CARD_SUMMARY_TEXT, classification: nil)

    assert_equal "summary_table", result.source
    assert_equal BigDecimal("435.88"), result.closing_balance
  end

  test "drops a summary table for an account it does not add up for" do
    assert_nil card_balances(CARD_SUMMARY_TEXT, classification: "asset")
  end

  test "reads a dollar sign in the statement's currency" do
    assert_equal "AUD", card_balances(CARD_LABELS_TEXT, classification: "liability", currency: "AUD").currency
    assert_equal "USD", card_balances(CARD_LABELS_TEXT, classification: "liability", currency: "USD").currency
    assert_nil card_balances(CARD_LABELS_TEXT, classification: "liability", currency: "EUR")
  end

  test "falls back to the labelled balances when the table is in another currency" do
    text = <<~TEXT
      Opening balance    Debits     Credits      Closing balance
      €1,066.47          €0.00      €1,502.35    €435.88 CR
      Opening balance AUD 1,000.00
      Closing balance AUD 900.00
    TEXT

    result = card_balances(text, classification: "liability")

    assert_equal "labels", result.source
    assert_equal BigDecimal("900.00"), result.closing_balance
  end

  test "reads a CR opening balance on a liability as in credit" do
    text = "Opening balance $435.88 CR\nClosing balance $120.00\n"

    result = card_balances(text, classification: "liability")

    assert_equal BigDecimal("-435.88"), result.opening_balance
    assert_equal BigDecimal("120.00"), result.closing_balance
  end

  test "leaves unmarked and DR balances on a liability as owed" do
    assert_equal BigDecimal("435.88"), card_balances(CARD_LABELS_TEXT.sub(" CR", ""), classification: "liability").closing_balance
    assert_equal BigDecimal("435.88"), card_balances(CARD_LABELS_TEXT.sub(" CR", " DR"), classification: "liability").closing_balance
  end

  test "reads a DR balance on an asset as overdrawn and a CR one as positive" do
    assert_equal BigDecimal("-435.88"), card_balances(CARD_LABELS_TEXT.sub(" CR", " DR"), classification: "asset").closing_balance
    assert_equal BigDecimal("435.88"), card_balances(CARD_LABELS_TEXT, classification: "asset").closing_balance
  end

  test "lets the marker set the sign of a minus-signed marked balance" do
    text = CARD_LABELS_TEXT.sub("$435.88 CR", "-$435.88 CR")

    assert_equal BigDecimal("-435.88"), card_balances(text, classification: "liability").closing_balance
    assert_equal BigDecimal("435.88"), card_balances(text, classification: "asset").closing_balance
  end

  # Only the balances take a marker's sign: the money in and out columns are
  # totals, read as printed.
  test "keeps a depository summary table with CR and DR on its totals" do
    text = <<~TEXT
      Opening balance    Credits      Debits      Closing balance
      $100.00 CR         $50.00 CR    $20.00 DR   $130.00 CR
    TEXT

    result = card_balances(text, classification: "asset")

    assert_equal "summary_table", result.source
    assert_equal BigDecimal("100.00"), result.opening_balance
    assert_equal BigDecimal("130.00"), result.closing_balance
  end

  test "reads a marker in any case, straight after the amount or after one space" do
    [ "$435.88CR", "$435.88 Cr", "$435.88 cr" ].each do |printed|
      result = card_balances(CARD_LABELS_TEXT.sub("$435.88 CR", printed), classification: "liability")

      assert_equal BigDecimal("-435.88"), result.closing_balance, printed
    end
  end

  test "does not read CR or DR further along the line as a marker" do
    text = CARD_LABELS_TEXT.sub("$435.88 CR", "$435.88    Dr Smith")

    assert_equal BigDecimal("-435.88"), card_balances(CARD_LABELS_TEXT.sub(" CR", " DR"), classification: "asset").closing_balance
    assert_equal BigDecimal("435.88"), card_balances(text, classification: "asset").closing_balance
  end

  test "drops a table that adds up only when its CR and DR markers are ignored" do
    text = <<~TEXT
      Opening balance    Debits     Credits      Closing balance
      $100.00 CR         $50.00     $0.00        $150.00 DR
    TEXT

    assert_nil AccountStatement::TextMetadataParser.parse(text)
  end

  test "does not read CR at the start of a word as a marker" do
    text = CARD_LABELS_TEXT.sub("$435.88 CR", "$435.88 CREDIT LIMIT $5,000.00")

    assert_equal BigDecimal("435.88"), card_balances(text, classification: "liability").closing_balance
  end

  TWO_DIGIT_YEAR_TEXT = <<~TEXT
    Period  3 Sep 21 - 1 Oct 21
    OPENING BALANCE  $1,250.00
    CLOSING BALANCE  $2,000.00
  TEXT

  def period_of(text)
    result = AccountStatement::TextMetadataParser.parse(text)
    result && [ result.period_start_on, result.period_end_on ]
  end

  test "reads a period printed with two-digit years" do
    assert_equal [ Date.new(2021, 9, 3), Date.new(2021, 10, 1) ], period_of(TWO_DIGIT_YEAR_TEXT)
  end

  test "reads a two-digit-year period across a year end" do
    assert_equal [ Date.new(2021, 12, 4), Date.new(2022, 1, 3) ], period_of("Period 4 Dec 21 - 3 Jan 22")
  end

  test "reads a two-digit-year period separated by Unicode spaces" do
    text = "Period\u00A03\u00A0Sep\u00A021\u202F-\u202F1\u00A0Oct\u00A021"

    assert_equal [ Date.new(2021, 9, 3), Date.new(2021, 10, 1) ], period_of(text)
  end

  test "reads a two-digit-year period with full month names" do
    assert_equal [ Date.new(2021, 4, 3), Date.new(2021, 5, 1) ], period_of("Period 3 April 21 - 1 May 21")
    assert_equal [ Date.new(2021, 12, 4), Date.new(2022, 1, 3) ], period_of("Period 4 December 21 - 3 January 22")
  end

  test "reads a two-digit-year period separated by a word" do
    assert_equal [ Date.new(2021, 9, 3), Date.new(2021, 10, 1) ], period_of("Period 3 Sep 21 to 1 Oct 21")
  end

  test "prefers a four-digit-year period to an earlier two-digit one" do
    text = "Previous period 3 Sep 21 - 1 Oct 21\nStatement period 1 Apr 2026 - 30 Apr 2026"

    assert_equal [ Date.new(2026, 4, 1), Date.new(2026, 4, 30) ], period_of(text)
  end

  test "does not read numeric two-digit years, other words or times as a period" do
    assert_equal [ nil, nil ], period_of(TWO_DIGIT_YEAR_TEXT.sub("3 Sep 21 - 1 Oct 21", "03/09/21 - 01/10/21"))
    assert_equal [ nil, nil ], period_of(TWO_DIGIT_YEAR_TEXT.sub("3 Sep 21 - 1 Oct 21", "2 Marketing 21 - 5 Marketing 21"))
    assert_equal [ nil, nil ], period_of(TWO_DIGIT_YEAR_TEXT.sub("3 Sep 21 - 1 Oct 21", "2 Marketing 21 - 3 Marketing 21"))
    assert_equal [ nil, nil ], period_of(TWO_DIGIT_YEAR_TEXT.sub("3 Sep 21 - 1 Oct 21", "1 Sep 20 - 1 Sep 2021"))
    assert_equal [ nil, nil ], period_of(TWO_DIGIT_YEAR_TEXT.sub("3 Sep 21 - 1 Oct 21", "11:28PM 14NOV - 11:30PM 15NOV $21.00"))
  end

  test "ignores text without a period or balances" do
    assert_nil AccountStatement::TextMetadataParser.parse("Invoice 2026-04 total 1.234,56 EUR due 15.05.2026")
    assert_nil AccountStatement::TextMetadataParser.parse("")
  end
end
