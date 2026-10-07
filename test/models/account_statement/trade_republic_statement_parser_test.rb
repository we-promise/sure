require "test_helper"

class AccountStatement::TradeRepublicStatementParserTest < ActiveSupport::TestCase
  # Text order as produced by a layout-preserving extractor.
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

  test "reads period, balances and IBAN from a layout statement" do
    result = AccountStatement::TradeRepublicStatementParser.parse(LAYOUT_TEXT)

    assert_equal Date.new(2025, 1, 1), result.period_start_on
    assert_equal Date.new(2025, 12, 31), result.period_end_on
    assert_equal BigDecimal("821.00"), result.opening_balance
    assert_equal BigDecimal("1944.58"), result.closing_balance
    assert_equal "EUR", result.currency
    assert_equal "1234", result.iban_last4
  end

  test "reads a statement whose cells are on separate lines" do
    result = AccountStatement::TradeRepublicStatementParser.parse(STACKED_TEXT)

    assert_equal Date.new(2026, 4, 1), result.period_start_on
    assert_equal Date.new(2026, 4, 30), result.period_end_on
    assert_equal BigDecimal("1101.14"), result.opening_balance
    assert_equal BigDecimal("11948.59"), result.closing_balance
  end

  test "understands German and English month names and amount formats" do
    german = "Trade Republic Bank GmbH\nDATUM 01 März 2026 - 31 März 2026\nANFANGSSALDO ZAHLUNGSEINGANG ZAHLUNGSAUSGANG ENDSALDO\n" \
      "Cashkonto 5.440,93 € 0,00 € 4.339,79 € 1.101,14 €"
    english = "Trade Republic Bank GmbH\nDATE 01 Sept 2026 - 30 Sept 2026\nOPENING BALANCE MONEY IN MONEY OUT CLOSING BALANCE\n" \
      "Cash account €4,324.20 €100.00 €2,577.30 €1,846.90"

    german_result = AccountStatement::TradeRepublicStatementParser.parse(german)
    assert_equal Date.new(2026, 3, 1), german_result.period_start_on
    assert_equal BigDecimal("1101.14"), german_result.closing_balance

    english_result = AccountStatement::TradeRepublicStatementParser.parse(english)
    assert_equal Date.new(2026, 9, 30), english_result.period_end_on
    assert_equal BigDecimal("4324.20"), english_result.opening_balance
    assert_equal BigDecimal("1846.90"), english_result.closing_balance
  end

  test "reads French statements and full month names" do
    french = "Trade Republic Bank GmbH\nDATE 01 juil. 2026 - 31 juil. 2026\nSYNTHÈSE DU RELEVÉ DE COMPTE\n" \
      "PRODUIT SOLDE D'OUVERTURE ENTRÉE D'ARGENT SORTIE D'ARGENT SOLDE DE FERMETURE\n" \
      "Compte courant 7 099,61 € 1 250,00 € 4 025,41 € 4 324,20 €"
    german = "Trade Republic Bank GmbH\nDATUM 01. Oktober 2025 - 31. Dezember 2025\nANFANGSSALDO\n100,00 € 50,00 € 25,00 € 125,00 €"

    french_result = AccountStatement::TradeRepublicStatementParser.parse(french)
    assert_equal Date.new(2026, 7, 1), french_result.period_start_on
    assert_equal Date.new(2026, 7, 31), french_result.period_end_on
    assert_equal BigDecimal("7099.61"), french_result.opening_balance
    assert_equal BigDecimal("4324.20"), french_result.closing_balance

    german_result = AccountStatement::TradeRepublicStatementParser.parse(german)
    assert_equal Date.new(2025, 10, 1), german_result.period_start_on
    assert_equal Date.new(2025, 12, 31), german_result.period_end_on
    assert_equal BigDecimal("125.00"), german_result.closing_balance
  end

  test "reads Spanish and Dutch long month names" do
    spanish = "Trade Republic Bank GmbH\nFECHA 01 septiembre 2026 - 30 septiembre 2026\nSALDO INICIAL\n10,00 € 5,00 € 1,00 € 14,00 €"
    dutch = "Trade Republic Bank GmbH\nDATUM 01 maart 2026 - 31 maart 2026\nBEGINSALDO\n10,00 € 5,00 € 1,00 € 14,00 €"

    spanish_result = AccountStatement::TradeRepublicStatementParser.parse(spanish)
    assert_equal Date.new(2026, 9, 1), spanish_result.period_start_on
    assert_equal Date.new(2026, 9, 30), spanish_result.period_end_on

    dutch_result = AccountStatement::TradeRepublicStatementParser.parse(dutch)
    assert_equal Date.new(2026, 3, 1), dutch_result.period_start_on
    assert_equal Date.new(2026, 3, 31), dutch_result.period_end_on
    assert_equal BigDecimal("14.00"), dutch_result.closing_balance
  end

  test "keeps the sign of negative balances in either currency position" do
    prefix = "Trade Republic Bank GmbH\nDATE 01 Aug 2026 - 31 Aug 2026\nOPENING BALANCE MONEY IN MONEY OUT CLOSING BALANCE\n" \
      "Cash account -€12.34 €100.00 €50.00 €37.66"
    inner = prefix.sub("-€12.34", "€-12.34")
    suffix = "Trade Republic Bank GmbH\nDATA 01 ago 2026 - 31 ago 2026\nSALDO INIZIALE\n10,00 € 0,00 € 22,34 € -12,34 €"

    [ prefix, inner ].each do |text|
      result = AccountStatement::TradeRepublicStatementParser.parse(text)
      assert_equal BigDecimal("-12.34"), result.opening_balance
      assert_equal BigDecimal("37.66"), result.closing_balance
    end

    assert_equal BigDecimal("-12.34"), AccountStatement::TradeRepublicStatementParser.parse(suffix).closing_balance
  end

  test "drops balances that do not add up" do
    text = LAYOUT_TEXT.sub("1.944,58 €", "1.999,99 €")

    result = AccountStatement::TradeRepublicStatementParser.parse(text)

    assert_equal Date.new(2025, 1, 1), result.period_start_on
    assert_nil result.opening_balance
    assert_nil result.closing_balance
    assert_nil result.currency
  end

  test "ignores statements from other institutions" do
    assert_nil AccountStatement::TradeRepublicStatementParser.parse(LAYOUT_TEXT.sub("TRADE REPUBLIC", "OTHER BANK"))
  end
end
