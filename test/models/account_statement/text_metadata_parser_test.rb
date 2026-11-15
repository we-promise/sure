require "test_helper"

class AccountStatement::TextMetadataParserTest < ActiveSupport::TestCase
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
    assert_equal BigDecimal("821.00"), result.opening_balance
    assert_equal BigDecimal("1944.58"), result.closing_balance
    assert_equal "EUR", result.currency
    assert_equal "1234", result.iban_last4
    assert_equal "summary_table", result.balances_source
  end

  test "reads a summary table whose cells are on separate lines" do
    result = AccountStatement::TextMetadataParser.parse(STACKED_TEXT)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal Date.new(2026, 4, 30), result.period_end_on
    assert_equal BigDecimal("1101.14"), result.opening_balance
    assert_equal BigDecimal("11948.59"), result.closing_balance
  end

  test "reads labelled balances, numeric dates and a grouped IBAN" do
    result = AccountStatement::TextMetadataParser.parse(GERMAN_TEXT)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal Date.new(2026, 4, 30), result.period_end_on
    assert_equal BigDecimal("1234.56"), result.opening_balance
    assert_equal BigDecimal("2000.00"), result.closing_balance
    assert_equal "EUR", result.currency
    assert_equal "3000", result.iban_last4
    assert_equal "labels", result.balances_source
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
    assert_equal BigDecimal("1250.00"), result.opening_balance
    assert_equal BigDecimal("1674.60"), result.closing_balance
    assert_equal "EUR", result.currency
    assert_equal "labels", result.balances_source
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
    assert_equal BigDecimal("1734.56"), result.closing_balance
    assert_equal "GBP", result.currency

    us = AccountStatement::TextMetadataParser.parse("Statement Period: April 1, 2026 through April 30, 2026")
    assert_equal Date.new(2026, 4, 1), us.period_start_on
    assert_equal Date.new(2026, 4, 30), us.period_end_on

    iso = AccountStatement::TextMetadataParser.parse("Period 2026-04-01 to 2026-04-30")
    assert_equal Date.new(2026, 4, 30), iso.period_end_on
  end

  test "reads a dollar amount only in the statement's dollar currency" do
    text = "Statement Period: April 1, 2026 through April 30, 2026\nBeginning Balance $2,500.00\nEnding Balance $3,100.25"

    usd = AccountStatement::TextMetadataParser.parse(text, currency: "USD")
    assert_equal BigDecimal("2500.00"), usd.opening_balance
    assert_equal "USD", usd.currency

    assert_nil AccountStatement::TextMetadataParser.parse(text, currency: "EUR").currency
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
    assert_nil result.opening_balance
    assert_nil result.closing_balance
    assert_nil result.balances_source
  end

  test "understands German and English month names and amount formats" do
    german = "DATUM 01 März 2026 - 31 März 2026\nANFANGSSALDO ZAHLUNGSEINGANG ZAHLUNGSAUSGANG ENDSALDO\n" \
      "Cashkonto 5.440,93 € 0,00 € 4.339,79 € 1.101,14 €"
    english = "DATE 01 Sept 2026 - 30 Sept 2026\nOPENING BALANCE MONEY IN MONEY OUT CLOSING BALANCE\n" \
      "Cash account €4,324.20 €100.00 €2,577.30 €1,846.90"

    german_result = AccountStatement::TextMetadataParser.parse(german)
    assert_equal Date.new(2026, 3, 1), german_result.period_start_on
    assert_equal BigDecimal("1101.14"), german_result.closing_balance

    english_result = AccountStatement::TextMetadataParser.parse(english)
    assert_equal Date.new(2026, 9, 30), english_result.period_end_on
    assert_equal BigDecimal("4324.20"), english_result.opening_balance
    assert_equal BigDecimal("1846.90"), english_result.closing_balance
  end

  test "reads French statements and full month names" do
    french = "DATE 01 juil. 2026 - 31 juil. 2026\nSYNTHÈSE DU RELEVÉ DE COMPTE\n" \
      "PRODUIT SOLDE D'OUVERTURE ENTRÉE D'ARGENT SORTIE D'ARGENT SOLDE DE FERMETURE\n" \
      "Compte courant 7 099,61 € 1 250,00 € 4 025,41 € 4 324,20 €"
    german = "DATUM 01. Oktober 2025 - 31. Dezember 2025\nANFANGSSALDO\n100,00 € 50,00 € 25,00 € 125,00 €"

    french_result = AccountStatement::TextMetadataParser.parse(french)
    assert_equal Date.new(2026, 7, 1), french_result.period_start_on
    assert_equal Date.new(2026, 7, 31), french_result.period_end_on
    assert_equal BigDecimal("7099.61"), french_result.opening_balance
    assert_equal BigDecimal("4324.20"), french_result.closing_balance

    german_result = AccountStatement::TextMetadataParser.parse(german)
    assert_equal Date.new(2025, 10, 1), german_result.period_start_on
    assert_equal Date.new(2025, 12, 31), german_result.period_end_on
    assert_equal BigDecimal("125.00"), german_result.closing_balance
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
    assert_equal BigDecimal("14.00"), dutch_result.closing_balance
  end

  test "keeps the sign of negative balances in either currency position" do
    prefix = "DATE 01 Aug 2026 - 31 Aug 2026\nOPENING BALANCE MONEY IN MONEY OUT CLOSING BALANCE\n" \
      "Cash account -€12.34 €100.00 €50.00 €37.66"
    inner = prefix.sub("-€12.34", "€-12.34")
    suffix = "DATA 01 ago 2026 - 31 ago 2026\nSALDO INIZIALE\n10,00 € 0,00 € 22,34 € -12,34 €"

    [ prefix, inner ].each do |text|
      result = AccountStatement::TextMetadataParser.parse(text)
      assert_equal BigDecimal("-12.34"), result.opening_balance
      assert_equal BigDecimal("37.66"), result.closing_balance
    end

    assert_equal BigDecimal("-12.34"), AccountStatement::TextMetadataParser.parse(suffix).closing_balance
  end

  test "drops balances that do not add up" do
    text = LAYOUT_TEXT.sub("1.944,58 €", "1.999,99 €")

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2025, 1, 1), result.period_start_on
    assert_nil result.opening_balance
    assert_nil result.closing_balance
    assert_nil result.currency
  end

  test "drops labelled balances in different currencies" do
    text = GERMAN_TEXT.sub("2.000,00 EUR", "2.000,00 USD")

    result = AccountStatement::TextMetadataParser.parse(text)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_nil result.opening_balance
    assert_nil result.closing_balance
  end

  test "ignores text without a period or balances" do
    assert_nil AccountStatement::TextMetadataParser.parse("Invoice 2026-04 total 1.234,56 EUR due 15.05.2026")
    assert_nil AccountStatement::TextMetadataParser.parse("")
  end
end
