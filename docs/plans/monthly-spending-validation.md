# Monatsausgaben – lokaler Prüfbericht

Stand: 10. Oktober 2026. Branch: `feature/monthly-spending-dashboard`, Basis `94e71a8c2` (`origin/main`). Autor ausschließlich für dieses Repository: `hescher <github@johecker.com>`.

Der lokale Preview umfasst Rails-Web, mobiles Web, API und die öffentliche Flutter-App. Kein Push, PR oder Merge. Eine separate lokale Preview ist nach Nutzerwahl deployed; kein Produktionsupdate. Das Projekt bis Feedback-Auswertung und v3 ist weiterhin offen; siehe [Projektplan](monthly-spending-dashboard.md).

## Ergebnisse

| Prüfung | Ergebnis |
| --- | --- |
| Vollständige Rails-Tests | 11.061 Tests, 46.985 Assertions, keine Fehler/Failures, 34 Skips. |
| Vollständige Flutter-Tests | 195 Tests bestanden. Nach dem letzten kleinen UI-Feinschliff zusätzlich alle sieben Monatsblock-Widgettests bestanden. |
| Feature-Browsertests und Property-Test isoliert | Final 3 Tests, 21 Assertions, keine Fehler/Failures. Echte Chrome-Emulation mit 390 px; kein Seitenüberlauf, interne Chart-Navigation, Tastatur, Suche, explizit leere Auswahl und Reset. |
| Vollständige Browser-Suite | 237 Tests, 1.177 Assertions, keine Failures, zwei Errors. Bestehender Property-Test findet „Edit“ im Gesamtlauf nicht; isoliert bestanden. Ein Screenshot-Rennen während Turbo-Ersetzung im neuen Test wurde durch eine explizite Wartebedingung korrigiert und fokussiert erfolgreich nachgeprüft. Gesamtsuite nach dieser Testkorrektur nicht erneut komplett ausgeführt; vor PR bleibt dieses Gate offen. |
| RuboCop | 2.899 Dateien ohne Befunde. Finale Testkorrektur zusätzlich einzeln ohne Befunde. |
| ERB-Lint | 756 Dateien, keine Fehler. |
| Biome-Lint | Projektcheck ohne Befunde; neue DS-Controller zusätzlich explizit mit Biome geprüft, da sie außerhalb der Standard-Include-Regel liegen. |
| Biome-Format | Projektweite Prüfung meldet 73 bestehende Formatfehler in unveränderten `app/javascript`-Dateien. Neue DS-Dateien bestehen den expliziten Format-/Lint-Check. Kein pauschales Umformatieren fremder Dateien. |
| Flutter analyze | Drei bestehende Info-Befunde in unverändertem `intro_screen_web.dart` (dart:html, Web-Library, Escape); Exit 1. Keine neuen Befunde. |
| Brakeman | Keine Fehler oder Security-Warnungen; neun bereits ignorierte Befunde. |
| API-Dokumentation | rswag: 439 Beispiele, keine Failures, 89 Pending im dokumentationsbezogenen Dry-run; OpenAPI regeneriert. Verhalten separat durch Minitest geprüft. |
| Git | Whitespace-Prüfung bestanden; temporäre Preview- und Lint-Hilfsdateien nicht Bestandteil des Commits. |

## Relevante überprüfte Fälle

- Gemeinsame Kontoberechtigungen und persönliche Preview-Freigabe, Familiengrenzen, OAuth/API-Key statt Browser-Session und fehlender Read-Scope.
- Haupt-/Unterkategorien, nicht kategorisierte Buchungen, Nullmonate und Dezember/Januar; Teilmonat und familienbezogener Stichtag.
- Bruttoausgaben, Erstattungen, Transfers, ausstehende/ausgeschlossene und zukünftige Buchungen, Reporting-Präferenzen sowie FX-Konvertierung und fehlende Kurse.
- Alle/Keine-Auswahl, ungültige/unberechtigte IDs, maximal 36 Monate und kein unbemerkter Rückfall auf ungefilterte Ergebnisse.
- Flutter: schmale Anzeige, große Schrift, Privacy-Modus, langsame konkurrierende Antworten, Fehler/alter Server/Preview aus, Monatswechsel und Filter-Presets.
- Diagrammskalierung auch bei kleinen Beträgen unter einer Währungseinheit.

## Bei der Prüfung behoben

- Reset verwendete anfänglich die POST-Voreinstellung von `DS::Button`; durch expliziten GET-Link ersetzt.
- Große native Schrift konnte Monatsbeschriftungen überlaufen lassen; Balkenbreite und Chart-Höhe passen sich dem Textmaßstab an.
- Initiale native Vorschau erschien vor bestätigter Berechtigung; der Block bleibt nun bis zum ersten erfolgreichen API-Ergebnis verborgen.
- Diagramm mit nur sehr kleinen Beträgen war unnötig flach; Skalierung verwendet den tatsächlichen positiven Höchstbetrag.
- Native Filter erklären jetzt auch Bereiche über 36 Monate; Kategorie-Details zeigen die passenden Segmentfarben.

## Noch keine Abnahme

Reale iOS-/Android-Geräte und Builds, Screenreader, 100k-Lastmessung, exakte Buchungsdrilldowns, dauerhafte Filterdefaults, Offline-Cache und zusätzliche Web-Größen/Theme-Varianten bleiben offen. Flutter verwendet die bestehenden Sprachen EN/SV, das Web EN/DE. Das frühere öffentliche Swift-Experiment wurde entfernt ([PR #3235](https://github.com/we-promise/sure/pull/3235)); eine weitere Swift-App ist nicht als geliefert anzusehen.

Vergleichsüberlagerungen folgen gemäß Projektplan in v2. CI, Review, Merge, Preview-Deployment, reales Nutzerfeedback und v3-Abnahme können erst mit den jeweiligen Ergebnissen abgeschlossen werden.

## Befehle zur Wiederholung

Im vorhandenen Entwicklungscontainer, Repository `/workspace`:

```sh
bin/rails test
DISABLE_PARALLELIZATION=true bin/rails test:system
DISABLE_PARALLELIZATION=true bin/rails test test/system/monthly_spending_test.rb test/system/property_test.rb
bin/rubocop
bundle exec erb_lint --lint-all
npm run lint
npm run format:check
bundle exec brakeman --no-pager
bundle exec rake rswag:specs:swaggerize
```

Im Flutter-Verzeichnis mit Flutter 3.32.4 / Dart 3.8.1:

```sh
flutter test
flutter analyze
```

Die Screenshots im gemeinsamen Workspace zeigen tatsächlich gerenderte Komponenten mit synthetischen Testdaten: `monthly-spending-desktop.png`, `monthly-spending-mobile.png`, `monthly-spending-flutter.png`.

## Live-Deployment-Check (10. Oktober 2026)

Separates lokales Compose-Projekt `sure-monthly-preview`, URL `http://localhost:3100`, App-Code `d6d652cd8`. Web, DB und Redis gesund; Worker läuft. Eigene Datenbank/Volumes und synthetische EUR-Daten; vorhandene Sure-Instanz unverändert. Port nur an `127.0.0.1` gebunden.

HTTP-Healthcheck 200; erfolgreiche Demo-Anmeldung und Monatsblock im Browser. Echte Monats-API: 200 mit zwölf EUR-Monaten und `private, no-store`; 401 ohne Schlüssel; explizit leere Kontenauswahl liefert einen leeren Bericht; umgekehrter Zeitraum liefert 422. Temporärer ausschließlich für diesen Check erzeugter Demo-Schlüssel nach der Prüfung entfernt. Kein nativer App-Build deployt.


## Preview-Feedback: Monatsfilter und Summen (10. Oktober 2026)

- Gemeldet: freies Monatsfeld akzeptiert `2025-2` nicht und springt nach einem Fehler zum Standardmonat; zusätzliche Monatssummen-Tabelle wirkt redundant.
- Behoben: plattformnative Monat-/Jahr-Auswahllisten, Normalisierung alter URLs mit einstelligen Monaten, Erhaltung ungültiger Entwürfe inklusive Konto-/Kategorienauswahl. Clientvalidierung blockiert umgekehrte, zukünftige und über 36 Monate lange Bereiche; Backendvalidierung bleibt maßgeblich.
- Monatsbeträge stehen direkt über den Balken im Web und in Flutter. Die bisher sichtbare Gesamttabelle ist ausschließlich als nicht fokussierbare Screenreader-Alternative vorhanden. Beträge und Diagrammgeometrie beachten weiterhin den Privatsphärenmodus.
- Filterinhalt scrollt innerhalb einer an die Viewporthöhe begrenzten Fläche; Anwenden bleibt im Fußbereich. Popovers werden auch vertikal innerhalb des Viewports gehalten. Suchhinweise stehen unmittelbar unter dem Suchfeld.
- Gezielte Regression: einstelliger Monat, erhaltene ungültige Auswahl, blockierter Zeitraum mit anschließender Korrektur, Tastaturbedienung und 390-px-Webansicht. Flutter: sieben Widgettests inkl. 320-px-Breite, doppelter Schriftgröße und Privatsphäre; gesamte Flutter-Suite 195 Tests erfolgreich.
- Weitere Wünsche zur nächsten Iteration: klarer „bis heute“-Hinweis am laufenden Monat, aktive Filter besser sichtbar, gespeicherte persönliche Filterauswahl. Vorjahresvergleich nur mit nachvollziehbarer Behandlung unvollständiger Monate.

Feedback-Validierung: gesamte Rails-Suite 11.063 Tests / 46.996 Assertions, null Fehler; drei gezielte Browser-Systemtests / 20 Assertions erfolgreich.

Feedback-Preview aus Code-Commit `ca98cf98e` erneut unter `http://localhost:3100` deployt. Web/Worker aktualisiert, vorhandene isolierte Preview-Daten und Layout behalten. Host-Healthcheck 200 und API-Smoke erfolgreich; im laufenden Browser Summenbeschriftungen und Monat-/Jahr-Auswahl bestätigt. Umgekehrter Entwurf blockiert Anwenden, bleibt stehen und lässt sich korrigieren. Native Änderungen sind getestet, weiterhin kein nativer App-Build deployt.


## V1-Feedback: Kategorieanteile und gespeicherte Filter

Umgesetzt am 10. Oktober 2026:

- Kategorieanteile in Web und Flutter, bezogen auf die gefilterte Monatssumme. Eine Nachkommastelle, lokalisierte Darstellung; keine Division durch null. Anteile werden im Datenschutzmodus zusammen mit den Geldbeträgen verborgen.
- Webfilter liegen pro Nutzer in bestehenden Datenbank-Präferenzen. Anwenden und Zeitraummenü speichern validierte Einstellungen per CSRF-geschütztem POST. GET und ungültige Entwürfe ändern die gespeicherte Auswahl nicht. Bestehende URL-Filter können weiterhin die aktuelle Ansicht vorgeben.
- Letzte zwölf Monate und dieses Jahr bleiben mitwandernde Zeiträume; ein gewähltes Kalenderjahr oder manuell veränderte Monatsgrenzen bleiben fest. Reset löscht die persönliche Auswahl und stellt den Standard wieder her.
- Native Filter liegen auf dem Gerät, getrennt nach Server-URL und Nutzer-ID. Nur IDs und Zeitraumwahl, keine finanziellen Ergebnisse. Wiederherstellung erfolgt vor der ersten Abfrage; Speichern nach erfolgreicher Antwort. Veraltete IDs bleiben über Reset korrigierbar. Keine Synchronisation der nativen Filter mit den Webpräferenzen in dieser Iteration.
- Prüfung: Rails komplett 11.067 Tests / 47.015 Assertions ohne Fehler (34 bestehende Skips); vier gezielte Browser-Systemtests / 24 Assertions erfolgreich. Flutter komplett 199 Tests erfolgreich. Ruby-/ERB-/JavaScript-Lint für Änderungen grün. Flutter analyze meldet weiterhin ausschließlich die drei bekannten Hinweise in intro_screen_web.dart.
- Schnellzeiträume und graue Hervorhebung des ausgewählten Monats bleiben bestehen. Zusätzliche sichtbare Filterhinweise sind auf Nutzerwunsch vertagt. Native Builds und die übrigen Release-Gates bleiben offen.
