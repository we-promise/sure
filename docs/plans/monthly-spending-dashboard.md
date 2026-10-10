# Projektplan: Monatsausgaben auf Home

Stand: 10. Oktober 2026. Status: lokaler v1-Preview implementiert, geprüft und separat auf diesem PC deployed; Produktionsrollout und v3 bleiben offen.

Lokaler Branch: `feature/monthly-spending-dashboard`.
Checkout: `/home/user/projects/sure` in WSL `Ubuntu-22.04`.
Basis: frisch abgerufenes `origin/main`, Commit `94e71a8c2`.
Die Bezeichnungen v1, v2 und v3 meinen Versionen dieser Funktion, keine Sure-App-Versionen.

## 1. Ziel und verbindlicher Umfang

Ein neuer, einklappbarer Home-Block „Ausgaben nach Monat“ zeigt monatliche Ausgaben als gestapelte Balken nach Kategorien. Er ergänzt Money In / Out und Spending. Desktop und mobiles Web gehören zur ersten Version. Native Mobile-Unterstützung ist ein eigener, verpflichtender Lieferstrang: dieselben serverseitigen Daten und Filter, aber plattformspezifische Darstellung. API-Verfügbarkeit allein gilt nicht als fertiggestellte native Ansicht.

Das Projekt endet erst nach Merge, realer Nutzung, bearbeitetem Feedback und Deployment einer überprüften v3. Ein gemergter Web-PR ist ein Zwischenziel.

Nutzer sollen beantworten können:

- Wie haben sich meine Ausgaben über die letzten Monate verändert?
- Welche Kategorien erklären einen teuren Monat?
- Wie sieht die Entwicklung ohne große Fixkosten aus?
- Welche Konten fließen in diese Zahlen ein?
- Wie unterscheidet sich ein Monat vom Vorjahr oder einem anderen Monat?

Erster Umfang: Kategorie-Balken, Zeitraumwahl, Mehrfach-Kontofilter, Kategorienfilter, Monatsdetails, zugängliche Tabelle und mobile Darstellung. Erweiterung: Vergleich mit Vorjahr bzw. ausgewählten Monaten. Konto-Aufteilung, Händlerberichte, Prognosen und Exporte sind nachrangige Wünsche; sie werden nicht ungeprüft in denselben PR aufgenommen.

## 2. Bisherige Designentscheidungen

| Thema | Vorgesehene Entscheidung |
| --- | --- |
| Platzierung | Neuer Home-Block, Standardposition nach Money In / Out; bestehende persönliche Reihenfolge respektieren. |
| Standardzeitraum | Letzte zwölf Kalendermonate einschließlich des laufenden Monats. |
| Zeitraumwahl | Letzte zwölf Monate, dieses Jahr, bestimmtes Jahr und eigener Bereich; Kalenderjahr als erster Standard. |
| Jahreswechsel | Chronologische Monatsfolge; Jahresgrenzen sichtbar, Detailansicht mit vollständigem Monat und Jahr. |
| Konten | Alle für den Benutzer zugänglichen und für diese Auswertung geeigneten Konten; Mehrfachauswahl analog zum bestehenden Kontofilter. |
| Kategorien | Alle standardmäßig; Auswahl gilt als Datenfilter und verändert Diagramm und sichtbare Summe gemeinsam. |
| Monat öffnen | Tippen/Klicken auf den Monat öffnet Summe, Kategorieaufteilung und Links zu den passenden Buchungen. |
| Mobile | Anzahl sichtbarer Monate aus verfügbarer Breite bestimmen: vier bis sechs statt zwölf zusammengedrängter Balken; horizontale Navigation nur innerhalb des Diagramms. |
| Erweiterte Ansicht | Größere Darstellung mit denselben Filtern; kein überraschendes Zurücksetzen beim Öffnen. |
| Speicherung | Persönliche Einstellungen, keine Family-weite Änderung; Filterzustand sichtbar und zurücksetzbar. |
| Erstes Rollout | Preview nach bestehender Sure-Konvention; Feature-Abschaltung ohne Änderung an Finanzdaten. |

„Alle Konten“ darf nicht Zugriff auf ungeteilte Konten bedeuten. Ein Konto-Filter und „nach Konten aufteilen“ sind verschiedene Funktionen. In v1 stehen Farben für Kategorien; ein Filterwechsel darf diese Bedeutung nicht verändern.

## 3. Datenregeln vor dem ersten Diagramm festlegen

### Vorhandene Architektur und Konsequenzen

Geprüft auf der genannten Basis:

- `PagesController` registriert Dashboard-Blöcke mit Layout, Sichtbarkeit, Reihenfolge und Parametern. Dort integrieren, nicht eine zweite Dashboard-Verwaltung aufbauen.
- `IncomeStatement::ScopedTransactionsQuery` enthält gemeinsame Regeln für Beträge, Konten und Klassifikation. Die Monatsaggregation muss diese Regeln wiederverwenden.
- Gewöhnliche Transfers und Kreditkartenzahlungen sind ausgeschlossen; Anlagebeiträge und Kreditraten zählen nach aktuellen Regeln zu Ausgaben. Nicht sämtliche Transfers pauschal herausfiltern.
- Der vorhandene SQL-Währungspfad hat `COALESCE(er.rate, 1)`. Fehlende Fremdwährungskurse können damit stille falsche Summen erzeugen. Das ist ein Prüfpunkt mit eigener Entscheidung, kein Anlass für eine unbemerkte globale Änderung im Chart-PR.
- `GET /api/v1/cash_flow` bietet Monatszahlen, Tagesvergleich und Sankey. Ein Vertrag für monatliche Kategorie-Balken ist zusätzlich zu definieren.
- `mobile/` enthält Flutter. Repository, Zugriff, Verantwortliche und Build-Weg der neuen nativen iOS-App sind noch zu verifizieren; Swift-Integration wird nicht als vorhandener Code angenommen.

### Entscheidungsprotokoll für die Berechnung

1. **Brutto und Erstattungen:** v1 übernimmt die bestehende Ausgabenklassifikation. Es ist zu prüfen, ob Erstattungen bereits als Ausgabenminderung gelten oder als Einnahmen erscheinen. Nicht eigenmächtig jede negative Buchung einer Ausgabenkategorie als Erstattung behandeln. Abweichungen zwischen Reports und Sankey dokumentieren. Soll eine Nettoansicht hinzukommen, benötigt sie eine klare Bezeichnung und konsistente Buchungsdetails.
2. **Negative Nettokategorien:** sollten nach späteren Refund-Regeln Werte unter null entstehen, nicht abschneiden. Lösung in Designphase prototypisieren: negative Segmente unter der Nulllinie oder getrennte Erstattungsanzeige mit eindeutig erklärter Summe. V1-Default muss vorher entschieden sein.
3. **Anlagebeiträge/Kredite:** bestehende Family-Präferenzen übernehmen, sobald upstream verfügbar. Die neue Ansicht darf #3952 bzw. #3461 nicht duplizieren und sollte ohne deren Merge lieferbar sein. Eine Beschriftung muss den derzeitigen Ausgabenbegriff verständlich machen.
4. **Kontoumfang:** gemeinsame Finance-/Reporting-Scopes und Benutzerrechte verwenden; ein vom Benutzer auswählbares Konto darf nicht still an anderer Stelle ausgeschlossen werden. Widersprüche im bestehenden Scope zuerst sichtbar machen und klären.
5. **Split-Buchungen:** Elternbetrag und Teilbeträge dürfen nicht doppelt zählen. Uncategorized sowie direkt auf Elternkategorien gebuchte Beträge bleiben erhalten.
6. **Zeit:** kalendarische Monate, Server-Stichtag und bekannte Zeitzonenregeln; API übermittelt Stichtag und Währung. Client bildet keine eigenen finanziellen Monatsgrenzen.
7. **Laufender Monat:** Betrag nur bis Stichtag; Label „bis …“. Vergleiche entweder bis zum gleichen Kalendertag oder zwischen abgeschlossenen Monaten. Keine Hochrechnung im Standarddiagramm.
8. **Eigener Zeitraum:** angeschnittene erste/letzte Monate markieren; im Detail tatsächliche Datumsgrenzen anzeigen. Ein monatlicher Balken ist dann kein voller Monat.
9. **Datenlücken:** keine Buchungen ist nicht automatisch vollständige Historie. „Keine Daten“, „0 €“ und ein nachweislich unvollständiger Import sind verschiedene Zustände. Wo historische Vollständigkeit unbekannt ist, nicht als vollständig ausgeben.
10. **Währungen:** Datumsbezogene Umrechnung in Family-Währung und präzise Dezimalarithmetik. Fehlende Kurse bzw. Teilresultate kennzeichnen; niemals unkommentiert eine 1:1-Umrechnung als korrekte Summe darstellen.
11. **Pending/ausgeschlossen:** dieselben Regeln wie die zugrunde liegende Berichtsansicht. Chart, Details, Tabelle und Transaktionslinks müssen denselben Umfang verwenden.
12. **Rundung:** intern exakt aggregieren, erst zur Darstellung runden. API liefert Decimal-Strings; gerundete Einzelwerte können kleine Differenzen zur gerundeten Summe haben.

Akzeptanz: Jede Monatsgesamtzahl lässt sich anhand eines festen Testdatensatzes auf die berücksichtigten Buchungen zurückführen; Filter verändern Chart, Tabelle und Details konsistent.

## 4. Risiken, Bedienungsprobleme und Gegenmaßnahmen

| Problem | Gegenmaßnahme / Prüfkriterium |
| --- | --- |
| Zu viele Kategorien und kaum sichtbare Segmente | Zu Beginn Hauptkategorien; Unterkategorien im Detail. Bei vielen Hauptkategorien stabiles Top-N über den gesamten gewählten Zeitraum plus „Weitere“. N im Prototyp bestimmen, nicht je Monat neu mischen. Alle Werte im Detail verfügbar. |
| Farben ändern beim Filtern ihre Bedeutung | Stabile Zuordnung nach Kategorie-ID; Farben und neutrale Gruppierung gemäß Sure-Design-System. Gleiche Farben in Balken, Legende und Detail. |
| Gleichnamige/umbenannte Kategorien | IDs statt Namen in Daten und Links; Namen lokalisierte Anzeige. Zusammenlegen/Löschen muss Cache und gespeicherte Auswahl bereinigen. |
| Große Wohnkosten verdecken übrige Änderungen | Kategorienfilter und transparente gefilterte Summe; keine automatische Ausblendung. |
| Monatsbalken auf Handy zu schmal | Vier bis sechs Monate gleichzeitig, sichtbare weitere Monate/Navigation; keine horizontal scrollende Gesamtseite. 320 px und große Schrift testen. |
| Wischen aktiviert versehentlich Monatsdetails | Öffnen erst nach Tap ohne Drag; Touch-Gesten und vertikales Seiten-Scrollen getrennt testen. |
| Zu kleine Farbsegmente nicht antippbar | Ganzer Monat als Auswahlziel; Kategorien über Liste oder Detail auswählen. Nicht auf winzige Segmente angewiesen sein. |
| Filter wirkt sofort, während „Anwenden“ angezeigt wird | Auswahl zunächst als Entwurf; Anwenden übernimmt, Abbrechen verwirft. „Alle“ und „Keine“ explizit unterscheiden; keine Auswahl darf nicht zu „Alle“ werden. |
| Versteckte Filter erklären niedrige Summen nicht | Kurze aktive Filteranzeige, ausgewählte Anzahl und Zurücksetzen. Bei Platzmangel ein gut erreichbarer Filterknopf mit Status. |
| Konten sind gelöscht oder nicht mehr geteilt | Zustand pro Server/Benutzer speichern; Auswahl neu validieren, Änderung erklären und keinen fremden Namen/Betrag anzeigen. |
| Langsame API überschreibt neue Auswahl | Vorherige Anfrage abbrechen oder Response-ID prüfen; nur Antwort zur aktuellen Auswahl rendern. |
| Nutzer wählt riesigen Zeitraum | Serverseitiges begrenztes Monatsfenster; UI sagt Grenze vor Anfrage. Vorschlag: maximal 36 Monate pro Antwort, lange Historie in Fenstern. Endgültig nach Lasttest entscheiden. |
| Viele Einzelabfragen pro Monat/Kategorie | Eine gruppierte Aggregation statt Schleifen über Monatsabfragen; keine Rohbuchungen zur Chart-Erzeugung an Mobile senden. |
| Stale Cache nach Sync/Filter/Berechtigung | Cache-Schlüssel umfasst Identität, Scope, Zeitraum, Filter, Währung, Reporting-Präferenzen und Änderungsstand. Berechtigungswechsel berücksichtigt. |
| Vergleich aktueller Teilmonat vs. voller Vorjahresmonat | Vergleichsmodus ausdrücklich benennen; gleicher Stichtag oder abgeschlossene Monate. Fehlende Vergleichsdaten separat markieren. |
| Farbenblindheit / Screenreader | Werte, Monatsdetail, zugängliche Tabelle und Tastaturzugang; Bedeutung nicht ausschließlich in Farbe kodieren. |
| Dunkelmodus, Privacy Mode, größere Schrift | Funktionale Tokens, Datenschutzmodus auf Chartwerte/Tooltips/Details anwenden; Layout darf nicht abschneiden. |
| Doppelte Home-Blöcke überfordern | Klare kurze Titel und unterschiedliche Zwecke; neue Funktion einklappbar/ausblendbar. Bestehende Dashboard-Personalisierung nutzen. |
| Native App auf älterem Server | Capability-/Versionserkennung, definierter Unsupported-Zustand; nicht Serverfehler in „0 €“ umdeuten. |
| Offline/Logout/Serverwechsel | Letzte Werte mit Zeitstempel anzeigen; Cache an Server und Benutzer binden und bei Logout/Rechtewechsel verwerfen. |

## 5. API und technische Umsetzung

Vorschlag: eigener read-only Monatsausgaben-Endpunkt oder sauber abgegrenzte additive Erweiterung des bestehenden Cashflow-Endpunkts. In Phase 1 nach Kompatibilitätsprüfung entscheiden. Bestehende monatliche Cashflow-Antwort bleibt kompatibel.

Vertrag enthält:

- Inklusive Datumsgrenzen, Monatsschlüssel `YYYY-MM`, Family-Währung und Stichtag.
- Validierte Konto-/Kategorie-IDs und vom Server angewandte Filter.
- Monatsgesamtwerte und Kategorie-Serien als Decimal-Strings mit stabilen IDs.
- Flags für laufende/angeschnittene Monate, bekannte Datenlücken und unvollständige Umrechnung.
- Expliziten Berechnungsmodus, damit Brutto-/Netto- und Beitragsregeln nicht verborgen sind.
- Klare Fehler für ungültige Daten, zu große Bereiche oder nicht zulässige Auswahl; keinen Rückfall auf alle Konten bei ungültigen IDs.
- Mehrfachauswahl, Eltern-/Kind-Auswahl und Uncategorized ohne doppelte Kategorien.

Model/PORO aggregiert; Controller authentifizieren, autorisieren und validieren. Web-Session und OAuth/API-Key bleiben getrennte Authentifizierungswege mit derselben Berechnung. Nur aktuelle zugängliche Konten dürfen in Metadaten und Summen erscheinen. HTTP-Antworten bleiben privat; Offline-Caches sind identitätsgebunden.

Web: bestehende DS-Komponenten und Chart-Konventionen verwenden; Dashboard-Schlüssel und Filterparameter in Customize-, Hide-/Show- und Expand-Abläufe integrieren. Keine globale Design-System-CSS-Änderung als impliziter Bestandteil.

Mobile: API-DTOs, native Chartdarstellung, Filteransicht, Detailnavigation, Tabellendarstellung und Auth-/Offline-Zustände. Für Swift ist ein gesonderter Checkout/PR und ein macOS-/Simulator-/Gerätetest einzuplanen. Windows/WSL bestätigt keinen funktionierenden iOS-Build.

## 6. Phasen von jetzt bis v3

| Phase | Arbeit und Ergebnis | Fertig, wenn … |
| --- | --- | --- |
| 0 — laufende Designphase | Diesen Plan, Screenshot-Bezug, Beispiel und Entscheidungen sammeln. Datenregeln, Mobile-Scope und offene Fragen protokollieren. | Plan im lokalen Branch; aktuelle Annahmen von bereits bestätigten Anforderungen getrennt. |
| 1 — technische Klärung und Design | Reporting-Regeln mit Beispieldaten abgleichen; Swift-Repo/Build-Zugang klären; offene PRs auf Überschneidung prüfen. Desktop-/Phone-Prototypen mit wenig/vielen Kategorien und Fehlerzuständen. | Datenvertrag, Kontoumfang, Refund-Regel, Filterbedienung und Mobile-Lieferweg festgelegt. |
| 2 — v1 implementieren | Gemeinsame Monatsaggregation und API, Web-Block, mobiles Web, Filter, Monatsdetail und zugängliche Tabelle. Native Implementierung im parallelen Lieferstrang, sobald Repo/Toolchain geklärt. | V1-Kernfunktionen und Zahlenprüfung bestehen; native Lücke ausdrücklich dokumentiert, falls noch offen. |
| 3 — v1 intern testen | Funktions-/API-/UI-Tests, viele Daten, echte Geräte, deutsche/englische Darstellung, Privacy und Berechtigungen. Isoliertes Test-Image bauen. | Keine bekannten falschen Summen/Rechteprobleme; Bedienung auf Desktop/Phone nachvollziehbar; erforderliche Checks grün. |
| 4 — Review, Preview-Merge und v1-Rollout | Kleine zusammenhängende Backend/Web- und Client-PRs, Screenshots, API-Doku, CI; Review-Anmerkungen bearbeiten. Nach Merge Release/Image-Abdeckung prüfen, Preview deployen. | Gemergter Code nachweislich im getesteten Image/Client-Build; Web und native Implementierung mit ihren tatsächlichen Ständen dokumentiert. |
| 5 — Feedback und v2 | Erste reale Nutzung über zwei bis vier Wochen; zusätzlich Monats-/Jahreswechsel in Tests simulieren. Bugs und Wünsche sammeln, reproduzieren, priorisieren. V2 beseitigt v1-Probleme; Jahresvergleich nur mit geklärter Regel. | Kritische Fehler behoben, wichtigste Reibungspunkte verbessert; v2 gemergt, deployt und Smoke-Test bestanden. |
| 6 — v2 validieren und v3 entwickeln | Zweite Feedbackrunde über zwei bis vier Wochen. Vergleich, viele Kategorien, kurze Historien und Gerätewechsel prüfen. Relevante Verbesserungen umsetzen; API-Kompatibilität und Performance erneut prüfen. | V3-Kandidat erfüllt Kernumfang auf Web und nativen Zielclients; offene Wünsche bewertet und dokumentiert. |
| 7 — v3 merge, deploy und Abschluss | Abschließendes Review/CI, Versionen und Images fixieren, Rollout; nach stabiler Nutzung Preview-Gate in eigenem PR entfernen, falls Maintainer zustimmen. Abschlussprotokoll. | V3 nachweislich läuft, reale und simulierte Übergangsfälle geprüft, kein offener kritischer Fehler; verbleibender Backlog und Zuständigkeiten festgehalten. |

Aufwand wird erst nach Phase 1 geschätzt. Backend/Web ist vom separat verfügbaren Swift-Projekt und dessen Release-Zyklus zu unterscheiden. Feedbackzeiten sind Beobachtungsfenster, keine zugesagten Termine. Kein Warten auf den echten Jahreswechsel: reproduzierbare Daten/Stichtage für November–Februar und Schaltjahr verwenden.

Ein Branch trägt die Designphase und v1. Nach dem ersten Merge kommen v2/v3 auf neue kleine lokale Branches vom dann aktuellen `main`; keinen dauerhaft divergierenden Feature-Branch pflegen. Neue App-Builds können zeitlich getrennt vom Server erscheinen; eine Kompatibilitätsmatrix begleitet jedes Release.

## 7. PR-Aufteilung und Überschneidungen

Vorgesehene reviewbare Einheiten:

1. Monatsaggregation + API + Dokumentation und Berechtigungstests.
2. Home-Block + mobiles Web + Filter/Details; integriert vorhandene Dashboard-Konventionen.
3. Native Client(s) mit DTOs, Chart und Filtern; eigene PRs passend zum jeweiligen Repository.
4. Feedback-Fixes und Vergleiche als kleine v2-/v3-PRs.
5. Preview-Gate entfernen nach bestätigter Stabilität.

Die ersten Einheiten können nach Maintainer-Abstimmung zusammengelegt werden, wenn der Umfang klein bleibt. Kein nutzloser öffentlicher API-Vertrag ohne absehbaren Client.

Relevante Vorhaben zum Abgleichen, nicht als ungeprüfte harte Abhängigkeiten:

- #4002: Spending vs normal / Treemap; dort angekündigte Kategorie-Trends könnten unsere Monatsaggregation nutzen.
- #3799: Sankey nach Konten; Kontofilter-Konventionen abstimmen.
- #3952 / #3461: Anlagebeiträge und Reporting-Präferenzen.
- #3428: Erstattungen als Ausgabenminderung.
- #4107: Händlerberichte; spätere Wiederverwendung der Monatsdaten prüfen.

Status dieser Vorhaben vor Implementierung und jedem Rebase erneut prüfen. Keine Commits anderer offener PRs still in unseren Branch übernehmen. Maintainer-Kommunikation, PR-Push und Produktionsdeployment sind spätere explizite Schritte; Plan und lokaler Branch sind erstellt; nach „go“ wurde ein lokaler v1-Preview umgesetzt. Push, PR und Merge sind noch nicht ausgeführt. Eine separate lokale Preview-Instanz ist inzwischen deployed; Produktionsdeployment bleibt offen.

## 8. Test- und Abnahmematrix

| Bereich | Pflichtfälle |
| --- | --- |
| Zahlen | Einzel-/Mehrkonten, Kreditkarte plus Zahlung, normale Transfers, Anlagebeiträge/Kreditrate, Split, Uncategorized, direkte Elternbuchung, Erstattung/negative Werte nach beschlossener Regel. |
| Zeit | Dez–Jan, Schaltjahr, Teilmonat, eigener Bereich mit Teilmonaten, leere/kurze Historie, alte Jahre, Stichtag im Client vs. Server. |
| Rechte | Andere Family, ungeteiltes Konto, gelöschtes/entzogenes Konto, manipulierte IDs, eingeloggter Webnutzer vs. OAuth/API-Key, Preview an/aus. |
| Filtern | Alle/einige/keine, Eltern/Kind, ungültige IDs, Anwenden/Abbrechen, Zurücksetzen, reload/back, Kontofilter plus Kategorienfilter. |
| Darstellung | 320/375/390 px, Tablet, Desktop halbe/volle Blockbreite, große Schrift, deutsch/englisch, Hell/Dunkel, Privacy, Tastatur/Screenreader, viele Kategorien und große Beträge. |
| Interaktion | Tap vs. Swipe, lange Kontonamen, Größenwechsel, Tooltip ohne Hover, Expand und Rückkehr, Hide/Show/Reihenfolge, Fehler/Retry, schnelle Filterwechsel. |
| Mobile | Unterstützte Flutter-/Swift-Zielgeräte tatsächlich testen; alter Server, Login/Logout, Serverwechsel, Offline/Refresh und Datenstand. |
| Last | 12/36 Monate, viele Konten/Kategorien, 10k/100k synthetische Buchungen; kalter/warmer Cache, SQL-Anzahl und Payload; keine monatlichen N+1-Abfragen. |

Vorläufige Performanceziele auf dokumentiertem Self-host-Testsystem: p95 für zwölf Monate unter 500 ms warm und unter 1,5 s kalt; Antwort unter 200 KB ohne Rohbuchungen. Werte in Phase 1 anhand Baseline bestätigen/ändern, keine unbelegte Produktionszusage. Ein versteckter Block soll keine teure Aggregation auslösen.

Vor jedem Implementierungs-PR gelten die Repository-Checks: vollständige Rails-Tests, relevante Systemtests, RuboCop, ERB-Lint, Biome, Brakeman, API-Minitest und dokumentationsbezogene rswag-Specs mit regeneriertem OpenAPI. Native Lint/Unit-/UI-/Build-Checks je Client zusätzlich. Fehlende iOS-Prüfung ist ein offenes Gate, kein bestandenes Ergebnis.

## 9. Deployments und Rückweg

1. Test-Image mit konkretem Commit bauen und unveränderlichen Tag/Digest dokumentieren.
2. Testinstanz benutzen; vor produktivem Update vorhandene Backup-/Restore-Prozedur prüfen. Anfangs keine Datenbankmigration erwarten; bei späterem Schemaänderungsbedarf Migration und Rückwärtskompatibilität getrennt bewerten.
3. Preview zunächst auf dem gewünschten Testbenutzer aktivieren. Server-Image und native Build-Version separat festhalten.
4. In Portainer das tatsächlich gewählte Image deployen; laufenden Commit/Digest nach Update überprüfen. Ein Merge allein bedeutet nicht, dass `stable` die Funktion bereits enthält.
5. Smoke-Test: Home lädt, Filter/Details stimmen, bestehende Blöcke bleiben bedienbar, Zugriffsschutz und Mobile funktionieren.
6. Rückweg: Feature ausblenden/Preview deaktivieren; gegebenenfalls vorheriges kompatibles Image verwenden. Datenbank-Rollback nicht automatisch durchführen.
7. Dasselbe Verfahren für v2 und v3; jeweils Änderungen, Checks, offene Punkte und Client-Kompatibilität dokumentieren.

## 10. Nutzerfeedback, Wünsche und Definition des Abschlusses

Feedbackprotokoll pro Fund: Version/Commit, Client/OS, reproduzierbare Schritte, erwartetes/tatsächliches Verhalten, anonymisierte Beispielzahlen, Priorität, Entscheidung und zugehöriger Fix/Test.

- P0: Daten-/Zugriffsverletzung oder grob falsche Finanzzahlen — Rollout stoppen, Feature abschalten, zuerst beheben.
- P1: Kernfunktion unbenutzbar, falsche Filter/Monatsgrenzen, Absturz — vor nächstem breiteren Rollout beheben.
- P2: störende Darstellung, Touch-/Legendenprobleme, langsame Antwort — v2/v3 priorisieren.
- P3: Erweiterungswünsche — nach Nutzen, Häufigkeit und Aufwand bewerten.

Wunschliste zum gezielten Prüfen: Vorjahresvergleich, beliebige Monatsvergleiche, gleiche Tage im laufenden Monat, Kategorie-Trends, Konto-Aufteilung, eigene Standardzeiträume, gespeicherte Filter, Haupt-/Unterkategorien, Bild/CSV-Export, Einnahmenansicht, abweichender Budgetmonatsbeginn, Ausgaben netto nach Erstattungen.

Feedback ohne neue Überwachung sammeln: direkte Rückmeldungen und vorhandene Test-/Diagnosewege. Keine Finanzbeträge, Konto-/Händlernamen oder Buchungstexte als neue Telemetrie. Falls Nutzungsmessung benötigt wird, Umfang und vorhandene Opt-outs zuerst abstimmen. Keine automatische Nachrichtenserie oder neue Automation durch diesen Plan.

Abschluss v3 setzt voraus:

- [ ] Web, mobiles Web und vereinbarte native Zielclients enthalten den Kernumfang; jede verbleibende Plattformlücke ist ausdrücklich vom Nutzer akzeptiert.
- [ ] Chart, Tabelle und Buchungsdetails stimmen unter denselben Filtern überein.
- [ ] Jahreswechsel, Teilmonat, Erstattungsregel, Transfers, Währungen und Rechte sind nachvollziehbar getestet.
- [ ] Alle aufgetretenen P0/P1-Probleme sind behoben und gegen Wiederauftreten getestet.
- [ ] Häufige Bedienungsprobleme wurden in v2/v3 bearbeitet; weitere Wünsche haben eine sichtbare Entscheidung statt stiller Auslassung.
- [ ] Erforderliche lokale Checks und CI sind grün; tatsächliche Images/Client-Builds dokumentiert.
- [ ] V3 ist gemergt, deployt und nach Deployment geprüft; Rückweg dokumentiert.
- [ ] Abschluss enthält behobene Punkte, verbleibende Einschränkungen und priorisierten Folge-Backlog.

## 11. Umsetzungsstand und nächste Gates

Stand 10. Oktober 2026: lokaler v1-Preview für Rails-Web, mobiles Web und die öffentliche Flutter-App. Noch kein Push, PR oder Merge. Nach Nutzerwahl ist eine separate lokale Preview mit Beispieldaten unter `http://localhost:3100` deployed; kein Update der bestehenden Sure-Instanz. Das Gesamtprojekt bis v3 bleibt offen.

### Bereits umgesetzt

- Home-Block standardmäßig nach Money In / Out; persönliche Reihenfolge, Sichtbarkeit und Breite aus der vorhandenen Dashboard-Konfiguration. Aggregation wird für versteckte oder nicht freigeschaltete Blöcke nicht ausgeführt.
- Gemeinsame serverseitige Monatsaggregation und dokumentiertes `GET /api/v1/monthly_spending`; Zugriff durch den authentifizierten Benutzer und dessen persönliche Preview-Einstellung.
- Zwölf Monate als Standard, eigene zusammenhängende Bereiche mit maximal 36 Monaten, Monats- und Jahresbeschriftung, Nullmonate und Kennzeichnung des laufenden Teilmonats.
- Suchbare Konto-/Hauptkategorie-Auswahl einschließlich „Nicht kategorisiert“, Alle/Keine, Anwenden und Zurücksetzen. Kategorienfilter ändern sowohl Balken als auch Summe. Ungültige oder unberechtigte IDs liefern einen Fehler; keine stille Ausweitung auf alle Konten.
- Bruttoausgaben nach bestehenden Reporting-Regeln: gewöhnliche Erstattungen bleiben Einnahmen, Transfers und ausstehende Buchungen ausgeschlossen, Anlagebeiträge/Kreditzahlungen nach gemeinsamer Klassifizierung. Familienwährung; fehlende Wechselkurse ausdrücklich als vorläufig markiert, vorhandener 1:1-Fallback bleibt sichtbar.
- Web: Tastatur-/Touch-Auswahl, Kategorie-Details, zugängliche Monatstabelle, intern horizontal scrollbares Diagramm, EN/DE und Privacy-Markierung.
- Flutter: echtes Home-Widget mit Filtern, Monatsdetails, Suche, Privacy-Modus, Fehler-/Retry-Behandlung nach bestätigtem Preview-Zugriff und Schutz gegen verspätete Antworten. 403/404 blenden die Ansicht aus; vor der ersten Zugriffsbestätigung erscheint kein Preview-Block. Bestehende App-Sprachen EN/SV; keine neue globale deutsche App-Lokalisierung.
- Keine Migration, neue Paketabhängigkeit oder neue Finanzdaten-Telemetrie.

### Native Plattform geklärt, Swift bleibt offen

Die öffentlich verfügbare mobile Implementierung liegt unter `mobile/` im Sure-Repository und verwendet Flutter für iOS/Android. Der frühere Swift-Prototyp wurde durch [PR #3235](https://github.com/we-promise/sure/pull/3235) entfernt. Bei der öffentlichen Suche wurde kein aktuelles separates Swift-Repository gefunden. Deshalb ist Flutter implementiert; falls die gemeinte „neue App“ ein weiterer Swift-Client ist, fehlen weiterhin Repository-Zugang und Integration. Siehe [Mobile README](https://github.com/we-promise/sure/blob/main/mobile/README.md) und [Clients](https://github.com/we-promise/sure/blob/main/docs/clients.md).

### Noch offene Abnahme- und Ausbaupunkte

| Punkt | Behandlung / Gate |
| --- | --- |
| Passende Buchungslinks | Vor breitem v1-Rollout klären. `Transaction::Search` klassifiziert Ausgaben anders als die gemeinsame Reporting-Abfrage; ein einfacher Link wäre bei Erstattungen, Beiträgen und Pending-Buchungen irreführend. Monats-/Kategoriedetails sind vorhanden, exakte Buchungsdrilldowns fehlen. |
| Echte Geräte und Builds | iOS-/Android-Build, reales Gerät, Screenreader und Serverwechsel prüfen. Widgettests und Chrome-Emulation ersetzen diese Abnahme nicht. Kein Xcode auf diesem Windows-Rechner. |
| Lastmessung | 10k/100k-Baseline, p95, Payload und Query-Zahl vor Rollout messen. Eine gruppierte Monatsabfrage vorhanden; Performanceziele bisher unbestätigt. |
| Vergleich | Vorjahr-/Monatsüberlagerung, gleiche Tage und klare Vergleichsbasis in v2; noch nicht implementiert. |
| Große Ansicht | Eigene Expand-/Fullscreen-Ansicht noch offen; bestehender Block-Breitenumschalter unterstützt. |
| Gespeicherte Filter | Web speichert validierte Filter pro Nutzer in Datenbank-Präferenzen; Flutter lokal pro Server/Nutzer auf dem Gerät. Mitwandernde Zeiträume und Reset umgesetzt. Synchronisation zwischen Web und App sowie Offline-Cache bleiben offen. |
| Web-Darstellung | 320/390 px, Tablet (768 px) und Desktop im Browser geprüft; kein Seitenüberlauf bei den geprüften Breiten. Halbe Breite, weitere Theme-Varianten und viele Kategorien zusätzlich manuell abnehmen. |
| Swift | Nur falls anderer Zielclient gemeint: Repository bestimmen und eigenen Lieferstrang umsetzen; nicht als geliefert zählen. |
| Review, CI und Rollout | Lokale Commits, isolierte Preview und erste Feedback-Verbesserungen liegen vor. Push/PR, native CI-Builds, Maintainer-Review, Merge und Produktionsrollout bleiben offen; weitere Feedback-Runden bis v3 folgen. |

### Prüfprotokoll

Automatische Resultate und konkrete Einschränkungen werden im [lokalen Prüfbericht](monthly-spending-validation.md) festgehalten. Synthetische Screenshots stammen aus echten Web-/Flutter-Komponenten, nicht aus produktiven Finanzdaten.

Als Nächstes den lokalen Preview anhand derselben Beispielzahlen prüfen, die offenen v1-Gates schließen und den PR-Schnitt abstimmen. Nach Merge und Preview-Deployment Feedback nach Abschnitt 10 aufnehmen, v2-Fixes und Vergleiche umsetzen, erneut deployen und v3 erst nach überprüfter Stabilisierung abschließen. Keine spätere Phase ohne Belege als fertig markieren.

## 12. Lokales Preview-Deployment

Am 10. Oktober 2026 nach Nutzerwahl „Separate Preview-Instanz“ auf diesem Windows-PC gestartet. URL `http://localhost:3100`, nur Loopback-Zugriff. Code `d6d652cd8`, Image `sure-monthly-spending-preview:d6d652cd8`, Manifest `sha256:5ace6905d5b311eefcc6184261bade695af98dbe2c821dde162cbcdab73c2f1b`.

Eigenes Compose-Projekt `sure-monthly-preview` mit PostgreSQL, Redis, Web und Worker; 36 Monate synthetische EUR-Buchungen mit zwei Konten. Die vorhandene Sure-Instanz und deren Daten wurden nicht geändert. Anmeldung und sichtbarer Monatsblock im Browser sowie echte API-Antworten für Read-Zugriff, explizit leere Auswahl, ungültigen Zeitraum und fehlende Authentifizierung geprüft. Preview Features beim Demo-Benutzer bereits an.

Compose-Datei, Seed und Start-/Stop-Hinweise liegen im gemeinsamen Workspace unter `preview-deployment/`; Zugangsdaten ausschließlich in dortigen lokalen Dateien, nicht im Repository. Native Builds und Zugriff von einem weiteren Gerät sind noch keine abgeschlossene Lieferung. Die v3-Abschlusskriterien aus Abschnitt 10 bleiben offen.


## Preview-Feedback: Monatsfilter und Summen (10. Oktober 2026)

- Gemeldet: freies Monatsfeld akzeptiert `2025-2` nicht und springt nach einem Fehler zum Standardmonat; zusätzliche Monatssummen-Tabelle wirkt redundant.
- Behoben: plattformnative Monat-/Jahr-Auswahllisten, Normalisierung alter URLs mit einstelligen Monaten, Erhaltung ungültiger Entwürfe inklusive Konto-/Kategorienauswahl. Clientvalidierung blockiert umgekehrte, zukünftige und über 36 Monate lange Bereiche; Backendvalidierung bleibt maßgeblich.
- Monatsbeträge stehen direkt über den Balken im Web und in Flutter. Die bisher sichtbare Gesamttabelle ist ausschließlich als nicht fokussierbare Screenreader-Alternative vorhanden. Beträge und Diagrammgeometrie beachten weiterhin den Privatsphärenmodus.
- Filterinhalt scrollt innerhalb einer an die Viewporthöhe begrenzten Fläche; Anwenden bleibt im Fußbereich. Popovers werden auch vertikal innerhalb des Viewports gehalten. Suchhinweise stehen unmittelbar unter dem Suchfeld.
- Gezielte Regression: einstelliger Monat, erhaltene ungültige Auswahl, blockierter Zeitraum mit anschließender Korrektur, Tastaturbedienung und 390-px-Webansicht. Flutter: sieben Widgettests inkl. 320-px-Breite, doppelter Schriftgröße und Privatsphäre; gesamte Flutter-Suite 195 Tests erfolgreich.
- Weitere Wünsche zur nächsten Iteration: klarer „bis heute“-Hinweis am laufenden Monat, aktive Filter besser sichtbar, gespeicherte persönliche Filterauswahl. Vorjahresvergleich nur mit nachvollziehbarer Behandlung unvollständiger Monate.


## V1-Feedback: Kategorieanteile und gespeicherte Filter

Umgesetzt am 10. Oktober 2026:

- Kategorieanteile in Web und Flutter, bezogen auf die gefilterte Monatssumme. Eine Nachkommastelle, lokalisierte Darstellung; keine Division durch null. Anteile werden im Datenschutzmodus zusammen mit den Geldbeträgen verborgen.
- Webfilter liegen pro Nutzer in bestehenden Datenbank-Präferenzen. Anwenden und Zeitraummenü speichern validierte Einstellungen per CSRF-geschütztem POST. GET und ungültige Entwürfe ändern die gespeicherte Auswahl nicht. Bestehende URL-Filter können weiterhin die aktuelle Ansicht vorgeben.
- Letzte zwölf Monate und dieses Jahr bleiben mitwandernde Zeiträume; ein gewähltes Kalenderjahr oder manuell veränderte Monatsgrenzen bleiben fest. Reset löscht die persönliche Auswahl und stellt den Standard wieder her.
- Native Filter liegen auf dem Gerät, getrennt nach Server-URL und Nutzer-ID. Nur IDs und Zeitraumwahl, keine finanziellen Ergebnisse. Wiederherstellung erfolgt vor der ersten Abfrage; Speichern nach erfolgreicher Antwort. Veraltete IDs bleiben über Reset korrigierbar. Keine Synchronisation der nativen Filter mit den Webpräferenzen in dieser Iteration.
- Prüfung: Rails komplett 11.067 Tests / 47.015 Assertions ohne Fehler (34 bestehende Skips); vier gezielte Browser-Systemtests / 24 Assertions erfolgreich. Flutter komplett 199 Tests erfolgreich. Ruby-/ERB-/JavaScript-Lint für Änderungen grün. Flutter analyze meldet weiterhin ausschließlich die drei bekannten Hinweise in intro_screen_web.dart.
- Schnellzeiträume und graue Hervorhebung des ausgewählten Monats bleiben bestehen. Zusätzliche sichtbare Filterhinweise sind auf Nutzerwunsch vertagt. Native Builds und die übrigen Release-Gates bleiben offen.


## 15. PR-Form und Screenshots

Entwurf und vier echte Aufnahmen liegen unter [PR-Entwurf](monthly-spending-pr.md).
Er folgt CONTRIBUTING und den üblichen UI-PRs des Projekts. Branch auf Main
`aa22875d1` aktualisiert; neue Pflichtchecks im Prüfbericht dokumentiert.
Native GitHub-CI, Review, Merge und weiterer Rollout bleiben eigene Schritte.
