# The vocabulary half of Transaction::LabelNormalizer. The engine next door knows
# how to strip a marker; every marker it strips is declared here, so adding a
# country is a data change in one file and no code moves.
#
# A pack is a region, not a language, because the two disagree where it matters
# most: en-US writes 09/02 for 2 September and en-GB writes it for 9 February.
# The pack that matched the label therefore carries the date order, which makes
# the label itself the evidence rather than the family's UI locale (a French
# self-hoster running the app in English is the common case, not the exotic one).
#
# Every pack is always active. Bank labels come from the bank, not from the
# user's settings, so scoping the vocabulary to a configured locale would mean
# the one setting nobody thinks to change silently disables normalization.
# Cross-region false positives are handled by curation instead: a token earns
# its place only if it cannot plausibly begin a real merchant name once anchored
# with \A and terminated with \b.
class Transaction::LabelNormalizer::Dictionary
  # Rails are tried in this order regardless of the order a pack lists them, and
  # the order encodes real ambiguities:
  #   fee before withdrawal, or "ATM FEE" reads as cash taken out at a merchant
  #     called FEE.
  #   loan_payment before refund, or "REMB PRET IMMO" and "LOAN REPAYMENT" read
  #     as money coming back rather than an instalment going out.
  #   refund before card, direct_debit and transfer, or "ANNULATION CB FNAC" and
  #     "Refund Card Payment to ASOS" keep the rail they reverse and group away
  #     from the purchase they reverse.
  RAIL_ORDER = %w[fee loan_payment refund withdrawal cheque card direct_debit transfer].freeze

  # Only the Americas write month first. Everything else in the packs below is
  # day first, so :mdy is stated and :dmy is the default.
  MDY_COUNTRIES = %w[US CA PH].freeze

  # Tokens are literal phrases, matched case-insensitively and anchored at the
  # start of the label. A Regexp is accepted where a literal cannot express the
  # constraint that keeps the token safe; the engine appends the trailer either
  # way, so a Regexp entry describes the marker only.
  #
  # Deliberately absent, because \b alone does not save them: bare KAUF
  # (KAUFLAND), GA (GALERIA), BAR (BARILLA), DEB (DEBENHAMS), VIS (VISTAPRINT),
  # BP (British Petroleum), SO, DR, CR, CASH (CASH CONVERTERS), CREDIT (CREDIT
  # UNION), bare PAYMENT and DEBIT, GEA (GEA Farm Technologies), BEA, IDEAL
  # (Ideal Standard), bare MAESTRO, GIRO, bare ATM (ATM SOLUTIONS bills under
  # its own name), CASHPOINT (a betting brand), CHAPS (a pub and barber trade
  # name), TED and DOC (TED Baker), and the bare two- and three-letter UK
  # transaction-type codes, which only ever reach a label when a CSV importer
  # concatenates two columns and cost more than they earn.
  PACKS = [
    {
      region: "fr",
      date_order: :dmy,
      rails: {
        "card" => [
          /(?:ACHAT\s+|PAIEMENT\s+)?(?:FACT(?:URE)?\s+CARTE|CARTE\s+BANCAIRE|CARTE|CB)\b/,
          /(?:PAIEMENT\s+)?PSC\b/
        ],
        "direct_debit" => [ /(?:PRLV|PRELEVEMENT|PRELEVMNT)(?:\s+SEPA)?(?:\s+DE)?\b/ ],
        "transfer" => [ /(?:VIR(?:EMENT)?)(?:\s+(?:SEPA|INST(?:ANTANE)?|RECU|EMIS|PERMANENT))*(?:\s+(?:DE|POUR|EN\s+FAVEUR\s+DE))?\b/ ],
        # GAB is the Quebec spelling of DAB and reaches French-language
        # Canadian labels that no English pack covers.
        "withdrawal" => [ /(?:RETRAIT)(?:\s+(?:DAB|GAB|CARTE|ESPECES))?\b/ ],
        "cheque" => [ /(?:CHEQUE|CHQ)(?:\s+N[O°]?)?\b/ ],
        "fee" => [ /(?:COMMISSION\s+D?\s*INTERVENTION|COMMISSION|FRAIS|AGIOS|COTIS(?:ATION)?)\b/ ],
        # Lookahead: only the ECHEANCE/REMB marker is consumed. Unlike CB or
        # PRLV SEPA, the word PRET names what is being paid, so dropping it
        # would turn "ECHEANCE PRET ETUDIANT" into the bare "ETUDIANT".
        "loan_payment" => [ /(?:ECH(?:EANCE)?|REMB(?:OURSEMENT)?)\b[\s:.\-]*(?=PRET\b)/ ],
        "refund" => [ /(?:AVOIR|ANNULATION|REMBOURSEMENT|REMBT|REMB)\b/ ]
      }
    },
    {
      region: "en_us",
      date_order: :mdy,
      rails: {
        "card" => [
          "RECURRING PAYMENT AUTHORIZED ON", "PURCHASE AUTHORIZED ON",
          "RECURRING CARD PURCHASE", "POINT OF SALE PURCHASE",
          "CARD PURCHASE WITH PIN", "DEBIT CARD PURCHASE", "RETAIL PURCHASE",
          "CHECKCARD", "CHKCARD", "POS PURCHASE", "POS DEBIT", "PIN PURCHASE"
        ],
        "direct_debit" => [
          "PREAUTHORIZED PAYMENT", "PREAUTHORIZED DEBIT", "AUTOMATIC PAYMENT",
          "ACH WITHDRAWAL", "ACH DEBIT"
        ],
        "transfer" => [
          "ONLINE BANKING TRANSFER", "EXTERNAL TRANSFER", "INTERNET TRANSFER",
          "PAYROLL DEPOSIT", "ONLINE TRANSFER", "DIRECT DEPOSIT",
          "MOBILE DEPOSIT", "WIRE TRANSFER", "INCOMING WIRE", "OUTGOING WIRE",
          "ZELLE PAYMENT", "ZELLE", "TRANSFER"
        ],
        "withdrawal" => [
          "ATM WITHDRAWAL AUTHORIZED ON", "ATM CASH WITHDRAWAL",
          "CASH WITHDRAWAL", "ATM WITHDRAWAL", "ATM WITHDRWL", "ATM DEBIT",
          "ATM CASH"
        ],
        "cheque" => [
          "MOBILE CHECK DEPOSIT", "RETURNED CHECK", "CHECK DEPOSIT",
          "CHECK NUMBER", "CHECK PAID", "CHECK NO",
          # Bare CHECK only when a number follows or nothing does. Without the
          # lookahead it eats CHECK INTO CASH and CHECK 'N GO, which are payees.
          /CHECK\b(?=[\s:.#-]*(?:\d|\z))/
        ],
        "fee" => [
          "INTERNATIONAL TRANSACTION FEE", "NON-SUFFICIENT FUNDS FEE",
          "MONTHLY MAINTENANCE FEE", "FOREIGN TRANSACTION FEE",
          "INSUFFICIENT FUNDS FEE", "RETURNED PAYMENT FEE",
          "MONTHLY SERVICE FEE", "RETURNED ITEM FEE", "LATE PAYMENT FEE",
          "CASH ADVANCE FEE", "ATM OPERATOR FEE", "INTEREST CHARGED",
          "SERVICE CHARGE", "INTEREST CHARGE", "OVERDRAFT FEE", "ANNUAL FEE",
          "LATE FEE", "NSF FEE", "ATM FEE"
        ],
        "loan_payment" => [
          "PERSONAL LOAN PAYMENT", "STUDENT LOAN PAYMENT", "INSTALLMENT PAYMENT",
          "AUTO LOAN PAYMENT", "MORTGAGE PAYMENT", "LOAN PAYMENT",
          "MORTGAGE PMT", "LOAN PMT"
        ],
        "refund" => [
          "REFUND PURCHASE AUTHORIZED ON", "PURCHASE RETURN AUTHORIZED ON",
          "PURCHASE RETURN", "MERCHANT REFUND", "MERCHANT CREDIT",
          "CARD REFUND", "CHARGEBACK", "REVERSAL", "REFUND"
        ]
      }
    },
    {
      region: "en_gb",
      date_order: :dmy,
      rails: {
        "card" => [
          "VISA DEBIT PURCHASE", "CONTACTLESS PAYMENT", "VISA PURCHASE",
          "CARD PURCHASE", "CARD PAYMENT",
          # Safe bare because \b keeps it off POSTBANK, POSTE ITALIANE and
          # POSTFINANCE, and it is how NatWest and Lloyds label a card payment.
          "POS"
        ],
        "direct_debit" => [ "DIRECT DEBIT PAYMENT", "DIRECT DEBIT", "D/D" ],
        "transfer" => [
          "FASTER PAYMENTS RECEIPT", "BANK GIRO CREDIT", "FASTER PAYMENT",
          "STANDING ORDER", "BILL PAYMENT", "DIRECT CREDIT", "BACS", "S/O"
        ],
        "withdrawal" => [ "CASH WITHDRAWAL" ],
        "cheque" => [ "CHEQUE DEPOSIT", "CHEQUE PAID", "CHEQUE NO" ],
        "fee" => [
          "NON-STERLING TRANSACTION FEE", "UNARRANGED OVERDRAFT FEE",
          "ARRANGED OVERDRAFT FEE", "PAPER STATEMENT FEE",
          "MONTHLY ACCOUNT FEE", "OVERDRAFT INTEREST", "BANK CHARGE",
          "ACCOUNT FEE"
        ],
        "loan_payment" => [ "MORTGAGE REPAYMENT", "LOAN INSTALMENT", "LOAN REPAYMENT" ],
        "refund" => [ "CREDIT VOUCHER" ]
      }
    },
    {
      region: "en_ca",
      date_order: :mdy,
      rails: {
        "card" => [
          "CONTACTLESS INTERAC PURCHASE", "INTERAC RETAIL PURCHASE",
          "INTERAC PURCHASE"
        ],
        "direct_debit" => [ "PRE-AUTHORIZED DEBIT" ],
        "transfer" => [
          "INTERAC E-TRANSFER", "E-TRANSFER RECEIVED", "E-TRANSFER SENT",
          "E-TRANSFER"
        ],
        "withdrawal" => [ "ABM CASH WITHDRAWAL", "ABM WITHDRAWAL" ]
      }
    },
    {
      region: "de",
      date_order: :dmy,
      rails: {
        "card" => [
          "KARTENZAHLUNG/-ABRECHNUNG", "KREDITKARTENABRECHNUNG",
          "MAESTRO KARTENZAHLUNG", "DEBITKARTENZAHLUNG", "KREDITKARTENUMSATZ",
          "KARTENZAHLUNG ONLINE", "SEPA-ELV-LASTSCHRIFT", "KAUF/DIENSTLEISTUNG",
          "KARTENABRECHNUNG", "KARTENVERFUEGUNG", "KARTENVERFÜGUNG",
          "GIROCARD-ZAHLUNG", "KARTENZAHLUNG", "TWINT ZAHLUNG", "POS-ZAHLUNG",
          "TWINT KAUF", "GIROCARD"
        ],
        "direct_debit" => [
          "SEPA-FIRMENLASTSCHRIFT", "SEPA FIRMENLASTSCHRIFT",
          "SEPA-BASISLASTSCHRIFT", "SEPA BASISLASTSCHRIFT",
          "EINZUGSERMAECHTIGUNG", "EINZUGSERMÄCHTIGUNG", "LASTSCHRIFTEINZUG",
          "ABBUCHUNGSAUFTRAG", "FIRMENLASTSCHRIFT", "EINMALLASTSCHRIFT",
          "SEPA-LASTSCHRIFT", "SEPA LASTSCHRIFT", "FOLGELASTSCHRIFT",
          "BASISLASTSCHRIFT", "ERSTLASTSCHRIFT", "LASTSCHRIFT",
          "ABBUCHUNG", "LASTSCHR.", "LSV+"
        ],
        "transfer" => [
          "UEBERWEISUNGSGUTSCHRIFT", "ÜBERWEISUNGSGUTSCHRIFT",
          "GUTSCHRIFT UEBERWEISUNG", "GUTSCHRIFT ÜBERWEISUNG",
          "ECHTZEIT-UEBERWEISUNG", "ECHTZEIT-ÜBERWEISUNG",
          "EINZELUEBERWEISUNG", "EINZELÜBERWEISUNG", "SAMMELUEBERWEISUNG",
          "SAMMELÜBERWEISUNG", "ONLINE-UEBERWEISUNG", "ONLINE-ÜBERWEISUNG",
          "SEPA-UEBERWEISUNG", "SEPA UEBERWEISUNG", "SEPA-ÜBERWEISUNG",
          "SEPA ÜBERWEISUNG", "LOHN/GEHALT/RENTE", "DAUERAUFTRAG",
          "UEBERWEISUNG", "ÜBERWEISUNG", "GEHALT/RENTE", "UMBUCHUNG",
          "UEBERTRAG", "ÜBERTRAG"
        ],
        "withdrawal" => [
          "BARGELDBEZUG AM BANCOMAT", "AUSZAHLUNG GELDAUTOMAT",
          "SB-BARGELDBEHEBUNG", "BARGELDAUSZAHLUNG", "BANKOMATBEHEBUNG",
          "BARGELDBEHEBUNG", "BARAUSZAHLUNG", "BARGELDBEZUG", "GELDAUTOMAT",
          "GELDBEZUG", "ABHEBUNG"
        ],
        "cheque" => [
          "VERRECHNUNGSSCHECK", "SCHECKEINREICHUNG", "SCHECKEINLOESUNG",
          "SCHECKEINLÖSUNG", "SCHECK"
        ],
        "fee" => [
          "KONTOFUEHRUNGSGEBUEHR", "KONTOFÜHRUNGSGEBÜHR",
          "KONTOFUEHRUNGSENTGELT", "KONTOFÜHRUNGSENTGELT",
          "RECHNUNGSABSCHLUSS", "ENTGELTABRECHNUNG", "ENTGELTABSCHLUSS",
          "SOLLZINSEN", "GEBUEHREN", "GEBÜHREN", "ENTGELTE", "GEBUEHR",
          "GEBÜHR", "ENTGELT", "SPESEN"
        ],
        # DARLEHEN and HYPOTHEK are absent on purpose: Dutch and German lenders
        # trade under those words (De Hypotheker, Hypotheek Visie), so a bare
        # token would strip the payee rather than the marker.
        "loan_payment" => [
          "DARLEHENSTILGUNG", "HYPOTHEKARZINSEN", "DARLEHENSZINSEN",
          "RATENZAHLUNG", "DARLEHENSRATE", "KREDITRATE", "ANNUITAET",
          "ANNUITÄT", "TILGUNG"
        ],
        "refund" => [
          "GUTSCHRIFT KARTENZAHLUNG", "WIEDERGUTSCHRIFT", "RUECKUEBERWEISUNG",
          "RÜCKÜBERWEISUNG", "RUECKERSTATTUNG", "RÜCKERSTATTUNG",
          "RUECKLASTSCHRIFT", "RÜCKLASTSCHRIFT", "STORNIERUNG",
          "RUECKBUCHUNG", "RÜCKBUCHUNG", "ERSTATTUNG", "RETOURE", "STORNO"
        ]
      }
    },
    {
      region: "es",
      date_order: :dmy,
      rails: {
        "card" => [
          "COMPRA CON TARJETA", "PAGO CON TARJETA", "COMPRA TARJETA",
          "PAGO TARJETA", "COMPRA"
        ],
        "direct_debit" => [
          "ADEUDO POR DOMICILIACION", "ADEUDO DOMICILIADO", "DOMICILIACION",
          "DOMICILIACIÓN", "ADEUDO", "RECIBO"
        ],
        "transfer" => [
          "TRANSFERENCIA RECIBIDA", "TRANSFERENCIA EMITIDA", "TRANSFERENCIA",
          "TRASPASO", "BIZUM", "NOMINA", "NÓMINA"
        ],
        "withdrawal" => [
          "DISPOSICION CAJERO", "RETIRADA EFECTIVO", "REINTEGRO CAJERO",
          "REINTEGRO"
        ],
        "fee" => [ "COMISION MANTENIMIENTO", "COMISION", "COMISIÓN" ],
        "loan_payment" => [
          "AMORTIZACION PRESTAMO", "CUOTA HIPOTECA", "CUOTA PRESTAMO"
        ],
        "refund" => [
          "ABONO POR DEVOLUCION", "DEVOLUCION", "DEVOLUCIÓN", "ANULACION",
          "ANULACIÓN"
        ]
      }
    },
    {
      region: "it",
      date_order: :dmy,
      rails: {
        "card" => [
          "PAGAMENTO TRAMITE POS", "PAGAMENTO CARTA", "PAGAMENTO POS",
          "ACQUISTO POS", "PAGOBANCOMAT"
        ],
        "direct_debit" => [
          "ADDEBITO PREAUTORIZZATO", "ADDEBITO DIRETTO", "ADDEBITO SDD",
          "ADDEBITO RID", "ADDEBITO"
        ],
        "transfer" => [
          "BONIFICO ISTANTANEO", "BONIFICO SEPA", "GIROCONTO", "BONIFICO"
        ],
        "withdrawal" => [ "PRELIEVO BANCOMAT", "PRELIEVO ATM", "PRELIEVO" ],
        "fee" => [
          "SPESE TENUTA CONTO", "IMPOSTA DI BOLLO", "CANONE MENSILE",
          "COMMISSIONI", "COMMISSIONE"
        ],
        "loan_payment" => [ "RATA FINANZIAMENTO", "RATA PRESTITO", "RATA MUTUO" ],
        "refund" => [ "ACCREDITO STORNO", "RIMBORSO", "STORNO" ]
      }
    },
    {
      region: "nl",
      date_order: :dmy,
      rails: {
        "card" => [
          "BETALING MET KREDIETKAART", "BETAALAUTOMAATTRANSACTIE",
          "BETALING MET DEBETKAART", "BETAALPASTRANSACTIE",
          "AANKOOP BANCONTACT", "BETALING BANCONTACT", "BETAALAUTOMAAT",
          "BEA, BETAALPAS", "BEA, APPLE PAY", "BEA, GOOGLE PAY"
        ],
        "direct_debit" => [
          "SEPA INCASSO ALGEMEEN DOORLOPEND", "SEPA INCASSO ALGEMEEN EENMALIG",
          "EUROPESE DOMICILIERING", "EUROPESE DOMICILIËRING",
          "SEPA INCASSO DOORLOPEND", "SEPA INCASSO EENMALIG",
          "DOORLOPENDE MACHTIGING", "SEPA DOMICILIERING", "SEPA DOMICILIËRING",
          "EUROPESE INCASSO", "SEPA INCASSO"
        ],
        "transfer" => [
          "SEPA PERIODIEKE OVERBOEKING", "PERIODIEKE OVERSCHRIJVING",
          "EUROPESE OVERSCHRIJVING", "INSTANTOVERSCHRIJVING",
          "SEPA SPOEDOVERBOEKING", "PERIODIEKE OVERBOEKING", "SEPA OVERBOEKING",
          "OVERSCHRIJVING", "OVERBOEKING", "SEPA IDEAL"
        ],
        "withdrawal" => [
          "GELDOPNEMING VIA AUTOMAAT", "GELDAFHALING BANCONTACT",
          "CONTANTE OPNAME", "GEA, BETAALPAS", "GELDAUTOMAAT", "GELDOPNEMING",
          "GELDAFHALING", "GELDOPNAME", "KASOPNAME"
        ],
        "cheque" => [ "CIRCULAIRE CHEQUE", "BANKCHEQUE" ],
        "fee" => [
          "BETAALPAKKET KOSTEN", "KOSTEN BETAALPAKKET", "TRANSACTIEKOSTEN",
          "BEHEERKOSTEN", "MAANDKOSTEN", "BANKKOSTEN", "DEBETRENTE"
        ],
        "loan_payment" => [
          "AFLOSSING HYPOTHEEK", "HYPOTHEEKTERMIJN", "AFLOSSING KREDIET",
          "AFLOSSING LENING", "AFLOSSING"
        ],
        "refund" => [
          "SEPA INCASSO TERUGBOEKING", "SEPA TERUGBOEKING", "TERUGSTORTING",
          "TERUGBOEKING", "STORNERING"
        ]
      }
    },
    {
      region: "pt",
      date_order: :dmy,
      rails: {
        "card" => [
          "PAGAMENTO COM CARTAO", "PAGAMENTO COM CARTÃO", "COMPRA COM CARTAO",
          "COMPRA COM CARTÃO", "COMPRA MULTIBANCO"
        ],
        "direct_debit" => [
          "DEBITO AUTOMATICO", "DÉBITO AUTOMÁTICO", "DEBITO DIRETO",
          "DÉBITO DIRETO"
        ],
        "transfer" => [
          "TRANSFERENCIA MB WAY", "TRANSFERÊNCIA", "PIX RECEBIDO",
          "PIX ENVIADO", "MB WAY", "PIX"
        ],
        "withdrawal" => [ "LEVANTAMENTO MB", "LEVANTAMENTO", "SAQUE" ],
        "fee" => [ "IMPOSTO SELO", "COMISSAO", "COMISSÃO", "TARIFA" ],
        "loan_payment" => [
          "PRESTACAO EMPRESTIMO", "PRESTAÇÃO EMPRÉSTIMO", "PRESTACAO CREDITO"
        ],
        "refund" => [ "ESTORNO", "DEVOLUCAO", "DEVOLUÇÃO" ]
      }
    }
  ].freeze

  # What may sit between a consumed marker and the merchant. A connector must be
  # followed by whitespace: a bare `AT\b` turns "Card Payment AT&T" into a
  # merchant called "T". DI and DA are deliberately absent, because
  # "COMPRA DA VINCI" would lose the half of the name that identifies it.
  CONNECTORS = [
    'EN\\s+FAVEUR\\s+DE', 'A\\s+FAVORE\\s+DI', 'A\\s+FAVOR\\s+DE',
    "FROM", "VOOR", "NAAR", "PARA", "VIA", "VON", "TO", "AT", "FOR", "DE"
  ].freeze
  SEPARATORS = %q([\s:.,#\-]*)
  TRAILER = "#{SEPARATORS}(?:(?:#{CONNECTORS.join('|')})\\s+)?"

  # How many leading characters of a marker key its bucket in the prefix index.
  # Two is the length of the shortest literal marker any pack declares.
  PREFIX_LENGTH = 2

  class << self
    # [ rail, date_order, pattern ], grouped by RAIL_ORDER and, within a rail,
    # longest marker first so "COMPRA COM CARTAO" is tried before "COMPRA" and
    # "SEPA INCASSO TERUGBOEKING" before "SEPA INCASSO".
    def entries
      @entries ||= RAIL_ORDER.flat_map { |rail| entries_for(rail) }.freeze
    end

    # The markers this label could possibly start with, in the order they must
    # be tried. get_uncategorized_transactions normalizes a whole window of
    # entries in one call, and trying every pattern against every label was the
    # dominant cost of that tool: most labels carry no marker at all and paid
    # for the full walk to learn it.
    #
    # Bucketing by the marker's first two characters answers that in one hash
    # lookup. Each candidate carries its position in #entries and the buckets
    # are pre-sorted on it, so a bucket is walked in the same order the full
    # list would have been. This is a speed-up, never a change of meaning.
    def candidates_for(label)
      buckets, loose = prefix_index

      buckets[label[0, PREFIX_LENGTH].to_s.upcase] || loose
    end

    def entries_for_rails(rails)
      entries.select { |entry| rails.include?(entry.first) }
    end

    def date_order_for_region(region)
      MDY_COUNTRIES.include?(region.to_s.upcase) ? :mdy : :dmy
    end

    private
      # [ buckets, loose ], where a candidate is [ position, rail, date_order,
      # pattern ]. A Regexp marker describes alternatives rather than one
      # literal prefix, so it has no bucket of its own and joins every bucket
      # as well as the fallback list; there are a handful of them.
      def prefix_index
        @prefix_index ||= begin
          buckets = Hash.new { |hash, key| hash[key] = [] }
          loose = []

          entries.each_with_index do |(rail, date_order, pattern), position|
            candidate = [ position, rail, date_order, pattern ]
            prefix = prefixes_by_position[position]

            prefix ? buckets[prefix] << candidate : loose << candidate
          end

          loose.freeze
          merged = buckets.transform_values { |bucket| (bucket + loose).sort_by(&:first).freeze }

          [ merged.freeze, loose ].freeze
        end
      end

      def prefixes_by_position
        RAIL_ORDER
          .flat_map { |rail| tokens_for(rail).map(&:first) }
          .map { |token| token.is_a?(Regexp) ? nil : token[0, PREFIX_LENGTH].upcase }
      end

      def entries_for(rail)
        tokens_for(rail).map { |token, order| [ rail, order, compile(token) ] }
      end

      # The single source of token order, so the prefix index and the compiled
      # entries cannot drift apart.
      def tokens_for(rail)
        PACKS
          .flat_map { |pack| Array(pack[:rails][rail]).map { |token| [ token, pack[:date_order] ] } }
          .uniq { |token, _| token.is_a?(Regexp) ? token.source : token }
          .sort_by { |token, _| -specificity(token) }
      end

      def specificity(token)
        token.is_a?(Regexp) ? token.source.length : token.length
      end

      # A literal token matches whole words only, with flexible whitespace, and
      # earns a trailing \b only when it ends in a word character: appending one
      # after "LSV+" or "LASTSCHR." would never match.
      def compile(token)
        return Regexp.new("\\A(?:#{token.source})#{TRAILER}", Regexp::IGNORECASE) if token.is_a?(Regexp)

        body = token.split(/\s+/).map { |part| Regexp.escape(part) }.join('\s+')
        boundary = token.match?(/\w\z/) ? '\b' : ""

        Regexp.new("\\A(?:#{body})#{boundary}#{TRAILER}", Regexp::IGNORECASE)
      end
  end
end
