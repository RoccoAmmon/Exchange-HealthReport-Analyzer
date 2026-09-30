# Changelog / Änderungsverlauf

Alle nennenswerten Änderungen an diesem Projekt.
Alle Änderungen an diesem Projekt werden in dieser Datei dokumentiert.
Format: [Keep a Changelog](https://keepachangelog.com/de/1.1.0/) · Versionierung: [Semantic Versioning](https://semver.org/lang/de/)

[Deutsch](#-deutsch) · [English](#-english) · [README](README.md)

---

## 🇩🇪 Deutsch

Legende: **Hinzugefügt** = neue Funktion · **Geändert** = Verhaltensänderung · **Behoben** = Fehlerkorrektur · **Sicherheit** = sicherheitsrelevant

### [1.1.6] – 2026-09-30

#### Hinzugefügt

- **Selbst-Elevation:** Ohne Adminrechte startet sich das Skript per UAC-Abfrage selbst erhöht neu und reicht alle Parameter durch (`TargetServer`, `LogPath`, `AutoRefreshMinutes`, `OverrideDays`, `EventLogHours`, `MaxEventsPerLog`, `Theme`); ersetzt das kommentarlos abbrechende `#Requires -RunAsAdministrator` (Laufzeitprüfung in `Initialize-Application` bleibt als Sicherheitsnetz)

#### Behoben

- **STA-Neustart** reicht jetzt ebenfalls alle Parameter durch (bisher fehlten `EventLogHours`, `MaxEventsPerLog`, `Theme`)

### [1.1.5] – 2026-09-30

#### Hinzugefügt

- **Suchfenster in der GUI:** Eventlog-Zeitraum direkt neben „Analysieren" umschaltbar (6/12/24/48/72 h, zweisprachig, themefähig, während der Analyse gesperrt); `-EventLogHours` bleibt als Startwert erhalten

#### Geändert

- **Standard-Suchfenster 12 h → 24 h** (Parameter `-EventLogHours`, README aktualisiert)

### [1.1.4] – 2026-09-30

#### Geändert

- **Info-Only-Fall kompakt:** Gibt es keinen Fehler-Eintrag im Zeitfenster (z. B. `MailboxSpace/StorageLogicalDriveSpaceMonitor` mit nur erfolgreichen Probes), erscheint `Info-Eintraege (N, kein Fehler im Zeitfenster)` mit max. 3 einzeiligen Einträgen ohne `Detail:`-Zeilen mit `Error=[null]`; `LogName`/`Level` entfallen in dieser Ansicht
- **Kürzere Details-Zeile:** interne IDs (`Identity`, `ResultId`, `WorkItemId`, `IsValid`, `ObjectState`, `ServicePriority`, `DefinitionCreatedTime`) werden aus `Details:` herausgefiltert
- **Hinweis-Logik:** der `LogIsEnabled`-Hinweis erscheint nur noch, wenn tatsächlich kein Fehler gefunden wurde (mögliche Erklärung), nicht mehr zusätzlich zum gefundenen Fehler
- **Live-Probe:** nicht manuell startbare Probes (z. B. `DatabaseSpaceProbe`) werden still übergangen statt eines verwirrenden `[ERROR]`-Eintrags

### [1.1.3] – 2026-09-30

#### Geändert

- **Übersichtlichere Fehlerdetails:** Treffer werden nach Relevanz getrennt – Monitor-/Probe-Namen sind starke Treffer, HealthSet/AppPool-Name allein nur schwache (fallen zurück, sobald starke Treffer existieren). Gibt es Fehler-Einträge (Level Fehler/Warnung oder `ResultType` 1/4), werden **nur diese** gezeigt (`Fehler-Eintraege (N)`); reine Info-Einträge (erfolgreiche Probes, RecoveryAction-Infos) werden nur noch gezählt (`+ N weitere Informations-Eintraege ausgeblendet`). Ohne Fehler werden weiterhin die Info-Treffer gezeigt
- **Live-Probe ohne Text:** liefert die Probe weder `Result` noch `Error`, steht explizit `Probe erfolgreich, kein Fehlertext (Monitor ggf. noch nicht zurueckgesetzt)` statt einer leeren Zeile

### [1.1.2] – 2026-09-30

#### Hinzugefügt

- **Live-Probe-Fallback:** Die Analyse führt bei ungesunden Monitoren automatisch die passende Probe (`Invoke-MonitoringProbe`, max. 2, DeepTest bevorzugt) aus und zeigt `Result`/`Error` direkt in den Details – liefert den echten Fehler auch bei vollständig deaktivierten Eventlogs
- **Probenauflösung:** `Get-MonitoringItemIdentity` wird in der Analyse mit abgefragt; die Detailansicht listet die Proben des HealthSets und zeigt einen konkreten `Invoke-MonitoringProbe`-Befehl mit echter Probe-Identity statt `<ProbeName>`-Platzhalter
- **Application-Log als zusätzliche Quelle:** Fehler/Warnungen des klassischen `Application`-Logs im Zeitfenster werden mit abgefragt und gematcht
- **Vollständige Monitordaten:** alle sonstigen nicht-leeren `Get-ServerHealth`-Properties werden als `Details:`-Zeile mitgeschleppt (fängt SE-Abweichungen ab); `IsStale=True` wird explizit gemeldet
- **Reaktivierungs-Hinweis:** sind alle `ManagedAvailability`-Logs deaktiviert und leer, erscheint der `wevtutil`-Befehl zum Reaktivieren

#### Geändert

- **Deaktivierte Logs werden trotzdem gelesen** (alte Events bleiben lesbar) und nur noch als Hinweis vermerkt – bisher wurden sie per `continue` komplett übersprungen
- **Unterscheidung:** `Keine Events lesbar` (alle Logs deaktiviert/leer) vs. `Keine passenden Eventlogs` (Events vorhanden, aber kein Treffer)

### [1.1.1] – 2026-09-30

#### Behoben

- **Leere Fehlerdetails bei Unhealthy (z. B. Rest.Protocol/RestDeepTestMonitor):** `Fehler/Count` blieb leer, weil `Get-ServerHealth` kein `RepeatCount`/`RedAlertCount` liefert (das sind `Get-HealthReport`-Felder). Die Analyse liest und zeigt jetzt die tatsächlichen `Get-ServerHealth`-Felder: erster Fehlerzeitpunkt (`FirstFailedTime`/`FirstAlertObservedTime`), letzte Ausführung (`LastExecutionTime`/`LastExecutionResult`), `Description`, `Error` und `Exception`; `Fehler/Count` fällt auf den Scan-Wert zurück bzw. zeigt `n/a`
- **Keine Eventlogs trotz Unhealthy:** `ProbeResult`/`MonitorResult`/`ResponderResult` sind auf Produktivservern aus Performance-Gründen oft deaktiviert (`LogIsEnabled=False`). Zusätzlich werden jetzt `Microsoft-Exchange-ManagedAvailability/Monitoring` (enthält die Eskalationsmeldung inkl. letztem Probe-Fehler) und `RecoveryActionResults` abgefragt; deaktivierte Diagnose-Logs erscheinen nur noch als Hinweis, nicht mehr als Analysefehler, sobald Treffer vorliegen
- **Generische Probe-Meldungen:** der echte Fehlertext steckt im Event-XML (`Error`, `Exception`, `ResultName`), nicht in `Message`. Die Analyse extrahiert diese XML-Details, bezieht sie ins Token-Matching ein und zeigt sie als `Detail:`-Zeile an
- **Niemals wieder leere Detailseite:** ohne direkten Treffer werden die neuesten `ManagedAvailability`-Einträge als Fallback plus ein `Invoke-MonitoringProbe`-Hinweis für die zugehörige Probe angezeigt
- **Quick Fix:** neuer `Rest`-Eintrag (`MSExchangeRestAppPool`) für `Rest.Protocol`

### [1.1.0] – 2026-09-23

#### Hinzugefügt

- **Darstellung umschaltbar (Hell/Dunkel)** zur Laufzeit über einen neuen Umschalter in der Kopfzeile; wirkt sofort auf Fenster, Container, DataGrid, Eingabefelder, Statusleiste und Fehler-Markierungen
- Neuer Parameter `-Theme` (`Light`/`Dark`) zur Wahl der Startdarstellung
- Zentral gepflegte Farbpaletten in `$Script:Themes` (je 15 Farbwerte pro Palette)
- Zweisprachige Dokumentation: ausführliche `README.md` mit Badges und Screenshots sowie dieser `CHANGELOG.md`
- Screenshots der hellen und dunklen Darstellung unter `docs/`

#### Geändert

- **Standarddarstellung ist jetzt hell** (zuvor ausschließlich dunkel)
- Auch der **Mail-Dialog** übernimmt die aktive Darstellung
- Fenstertitel, Logdateiname und HTML-Fußzeile verwenden die korrigierte Schreibweise **Analyzer**
- `Set-UiTheme` arbeitet zweigleisig: lokale Pinselwerte für direkt gebundene Eigenschaften, Ressourcen-Ersetzung für Style-Setter

#### Behoben

- **ComboBox, ComboBoxItem und CheckBox waren im Dunkelmodus unlesbar**: die WPF-Standardvorlagen ignorieren `Background`/`Foreground` und zeichnen einen hellen Systemverlauf. Alle drei Steuerelemente besitzen nun eigene `ControlTemplate`s, die die Farben der aktiven Palette über `TemplateBinding` übernehmen
- Theme-Wechsel für direkt gebundene Eigenschaften (Fenster, DataGrid, Status-/Hinweistexte) führte zu Laufzeitausnahmen und blieb ohne Wirkung
- DataGrid-Kopfzeilen- und Zeilenstil (inklusive Rot/Gelb-Trigger) wird jetzt passend zur Palette neu erzeugt

### [1.0.1] – 2026-09-23

#### Behoben

- **Re-Test:** `Get-MonitoringItemIdentity` wird korrekt mit dem HealthSet-Namen aufgerufen; die Probe-Identity für `Invoke-MonitoringProbe` ist zweiteilig (`HealthSet\Probe`); die Ergebnis-Eigenschaft `ProbeResult` wird ausgewertet; kein Blindaufruf mehr, wenn keine Probe ermittelbar ist
- **Override:** `-PropertyValue 'False'` wird als String übergeben; Ausgabe vollständig über `Select-Object *`
- **Eventlogs:** lokaler Zugriff ohne `-ComputerName`, Log-Aktivierung wird vorab geprüft (`LogIsEnabled`), der Fallback respektiert das Zeitfenster `-EventLogHours`, zusätzliches Log `ResponderResult`
- **Eventzuordnung:** Treffer über Monitor-, Basis-, HealthSet- und Zielressourcen-Begriffe (vorher nur über den Monitornamen)
- **Exchange-Initialisierung:** Subscription-Edition-Snapin zuerst, Prüfung mit `Get-PSSnapin -Registered`, Fallback über `RemoteExchange.ps1`
- **Quick Fix:** exakter Treffer vor Teilstring (behebt Mehrdeutigkeiten wie `FrontendTransport` vs. `Transport`); veraltete Einträge (`RpcProxy`, `Inference`, `UnifiedMessaging`) entfernt, fehlende ergänzt (`MSExchangeDiagnostics`, `MSExchangeRpcClientAccess`, `MSExchangePushNotifications`, `MSExchangeEdgeSync`, `WinDefend`)
- **Namenskonvention:** ausschließlich zulässige Verben (`Write-AsyncError`, `Add-DetailsText`); keine Zuweisung an die Automatikvariable `$event`
- **Scope:** Empfängerliste des Mailversands wird im Skriptscope gehalten, damit der Hintergrund-Handler sie sicher liest
- **Mail-Dialog:** Senden- und Abbrechen-Schaltfläche sind während des Versands gesperrt
- STA-Neustart: Argumentliste wird korrekt zusammengesetzt

### [1.0.0] – 2026-09-23

#### Hinzugefügt

- Erstveröffentlichung des **Exchange HealthReport Analyzer** als WPF-GUI-Werkzeug (XAML inline im Skript)
- Initialer Scan mit `Get-HealthReport`, Anzeige ausschließlich ungesunder Checks (`AlertValue -ne 'Healthy'`) inklusive roter/gelber Zeilenmarkierung
- Deep-Dive-Analyse mit `Get-ServerHealth` und Auswertung der ActiveMonitoring-Eventlogs (`ProbeResult`, `MonitorResult`)
- Admin-Aktionen: **Analysieren**, **Jetzt Re-Testen** (`Invoke-MonitoringProbe`), **Override setzen** (`Add-ServerMonitoringOverride`), **Quick Fix** für Dienste und IIS-AppPools
- HTML-Export über `SaveFileDialog` und Mailversand über einen eigenen SMTP-Dialog
- Zweisprachige Oberfläche (Deutsch/Englisch) mit Umschaltung zur Laufzeit, inklusive HTML-Report
- Auto-Refresh-Timer, Zielserver-Eingabe, Status- und Ladeanzeige
- Asynchrone Ausführung über Runspaces und `DispatcherTimer` – die Oberfläche bleibt reaktionsfähig
- Protokollierung nach `C:\ScriptLog`, umfassende Fehlerbehandlung, erzwungene Administratorrechte

---

## 🇬🇧 English

Legend: **Added** = new feature · **Changed** = behaviour change · **Fixed** = bug fix · **Security** = security related

### [1.1.6] – 2026-09-30

#### Added

- **Self-elevation:** without admin rights the script restarts itself elevated via UAC prompt and passes through all parameters (`TargetServer`, `LogPath`, `AutoRefreshMinutes`, `OverrideDays`, `EventLogHours`, `MaxEventsPerLog`, `Theme`); replaces the silently aborting `#Requires -RunAsAdministrator` (runtime check in `Initialize-Application` remains as a safety net)

#### Fixed

- **STA relaunch** now also passes through all parameters (previously missing `EventLogHours`, `MaxEventsPerLog`, `Theme`)

### [1.1.5] – 2026-09-30

#### Added

- **Time window in the GUI:** event log search period switchable directly next to "Analyse" (6/12/24/48/72 h, bilingual, theme-aware, locked during analysis); `-EventLogHours` remains as the initial value

#### Changed

- **Default search window 12 h → 24 h** (`-EventLogHours` parameter, README updated)

### [1.1.4] – 2026-09-30

#### Changed

- **Compact info-only case:** when no error entry exists in the time window (e.g. `MailboxSpace/StorageLogicalDriveSpaceMonitor` with only successful probes), an `Informational entries (N, no error in time window)` list with max. 3 single-line entries and no `Detail:` lines containing `Error=[null]` is shown; `LogName`/level are omitted in this view
- **Shorter details line:** internal IDs (`Identity`, `ResultId`, `WorkItemId`, `IsValid`, `ObjectState`, `ServicePriority`, `DefinitionCreatedTime`) are filtered out of `Details:`
- **Hint logic:** the `LogIsEnabled` hint only appears when no error was actually found (possible explanation), no longer on top of a found error
- **Live probe:** probes that cannot be run manually (e.g. `DatabaseSpaceProbe`) are silently skipped instead of a confusing `[ERROR]` entry

### [1.1.3] – 2026-09-30

#### Changed

- **Cleaner error details:** matches are ranked by relevance – monitor/probe names are strong matches, health set/app pool name alone is weak (used only when no strong match exists). When error entries exist (level error/warning or `ResultType` 1/4), **only those** are shown (`Error entries (N)`); pure informational entries (successful probes, RecoveryAction infos) are only counted (`+ N further informational entries hidden`). Without errors, informational matches are still shown
- **Empty live probe:** when the probe returns neither `Result` nor `Error`, an explicit `Probe succeeded, no error text (monitor may not have reset yet)` is shown instead of an empty line

### [1.1.2] – 2026-09-30

#### Added

- **Live probe fallback:** analysis automatically runs the matching probe (`Invoke-MonitoringProbe`, max. 2, DeepTest preferred) for unhealthy monitors and shows `Result`/`Error` in the details – yields the real error even with all event logs disabled
- **Probe resolution:** `Get-MonitoringItemIdentity` is queried during analysis; the details list the health set probes and show a concrete `Invoke-MonitoringProbe` command with the real probe identity instead of a `<ProbeName>` placeholder
- **Application log as an extra source:** errors/warnings from the classic `Application` log in the time window are queried and matched
- **Complete monitor data:** all other non-empty `Get-ServerHealth` properties are carried along as a `Details:` line (covers SE deviations); `IsStale=True` is reported explicitly
- **Re-enable hint:** when all `ManagedAvailability` logs are disabled and empty, the `wevtutil` command to re-enable them is shown

#### Changed

- **Disabled logs are still read** (old events remain readable) and only noted as a hint – previously they were skipped entirely via `continue`
- **Distinction:** `No events readable` (all logs disabled/empty) vs. `No matching events` (events exist but no match)

### [1.1.1] – 2026-09-30

#### Fixed

- **Empty failure details on Unhealthy (e.g. Rest.Protocol/RestDeepTestMonitor):** `Failures` stayed empty because `Get-ServerHealth` has no `RepeatCount`/`RedAlertCount` (those are `Get-HealthReport` fields). Analysis now reads and shows the real `Get-ServerHealth` fields: first failure time, last execution time/result, `Description`, `Error` and `Exception`; the counter falls back to the scan value or `n/a`
- **No event logs despite Unhealthy:** `ProbeResult`/`MonitorResult`/`ResponderResult` are often disabled on production servers for performance (`LogIsEnabled=False`). `Microsoft-Exchange-ManagedAvailability/Monitoring` (escalation message incl. most recent probe error) and `RecoveryActionResults` are now queried as well; disabled diagnostic logs are shown as a hint only when matches exist
- **Generic probe messages:** the real error text lives in the event XML (`Error`, `Exception`, `ResultName`), not in `Message`. Analysis extracts these XML details, includes them in token matching and shows them as a `Detail:` line
- **Never an empty details page again:** without a direct match, the newest `ManagedAvailability` entries are shown as a fallback plus an `Invoke-MonitoringProbe` hint for the related probe
- **Quick fix:** new `Rest` mapping (`MSExchangeRestAppPool`) for `Rest.Protocol`

### [1.1.0] – 2026-09-23

#### Added

- **Switchable appearance (light/dark)** at runtime via a new header control; applies instantly to window, panels, data grid, input fields, status bar and error highlighting
- New parameter `-Theme` (`Light`/`Dark`) to choose the initial appearance
- Centralised colour palettes in `$Script:Themes` (15 colour values per palette)
- Bilingual documentation: comprehensive `README.md` with badges and screenshots plus this `CHANGELOG.md`
- Light and dark theme screenshots in `docs/`

#### Changed

- **Default appearance is now light** (previously dark only)
- The **mail dialog** also follows the active appearance
- Window title, log file name and HTML footer use the corrected spelling **Analyzer**
- `Set-UiTheme` now works on two tracks: local brush values for directly bound properties and resource replacement for style setters

#### Fixed

- **ComboBox, ComboBoxItem and CheckBox were unreadable in dark mode**: the default WPF templates ignore `Background`/`Foreground` and paint a light system gradient. All three controls now use custom `ControlTemplate`s that take the palette colours via `TemplateBinding`
- Switching themes failed with runtime exceptions for directly bound properties (window, data grid, status/hint texts) and had no effect
- Data grid column header and row styles (including the red/yellow triggers) are now rebuilt for the active palette

### [1.0.1] – 2026-09-23

#### Fixed

- **Re-test:** `Get-MonitoringItemIdentity` is called with the health set name; the probe identity for `Invoke-MonitoringProbe` is two-part (`HealthSet\Probe`); the `ProbeResult` property is evaluated; no blind invocation when no probe can be determined
- **Override:** `-PropertyValue 'False'` is passed as a string; output uses `Select-Object *`
- **Event logs:** local access without `-ComputerName`, log enablement is checked upfront (`LogIsEnabled`), the fallback respects the `-EventLogHours` window, additional `ResponderResult` log
- **Event matching:** matches on monitor, base name, health set and target resource terms (previously monitor name only)
- **Exchange initialisation:** Subscription Edition snap-in first, `Get-PSSnapin -Registered` check, `RemoteExchange.ps1` fallback
- **Quick fix:** exact match before substring (fixes ambiguity such as `FrontendTransport` vs. `Transport`); outdated entries removed (`RpcProxy`, `Inference`, `UnifiedMessaging`), missing ones added (`MSExchangeDiagnostics`, `MSExchangeRpcClientAccess`, `MSExchangePushNotifications`, `MSExchangeEdgeSync`, `WinDefend`)
- **Naming:** approved verbs only (`Write-AsyncError`, `Add-DetailsText`); no assignment to the automatic variable `$event`
- **Scope:** the mail recipient list is kept in the script scope so the background handler can read it safely
- **Mail dialog:** send and cancel buttons are disabled while sending
- STA relaunch: argument list is assembled correctly

### [1.0.0] – 2026-09-23

#### Added

- Initial release of the **Exchange HealthReport Analyzer** as a WPF GUI tool (inline XAML)
- Initial scan via `Get-HealthReport`, showing unhealthy checks only (`AlertValue -ne 'Healthy'`) with red/yellow row highlighting
- Deep-dive analysis via `Get-ServerHealth` and evaluation of ActiveMonitoring event logs (`ProbeResult`, `MonitorResult`)
- Admin actions: **Analyse**, **Re-test now** (`Invoke-MonitoringProbe`), **Set override** (`Add-ServerMonitoringOverride`), **Quick fix** for services and IIS app pools
- HTML export via `SaveFileDialog` and mail delivery through a dedicated SMTP dialog
- Bilingual UI (German/English) switchable at runtime, including the HTML report
- Auto-refresh timer, target server input, status and busy indicators
- Asynchronous execution via runspaces and `DispatcherTimer` – the UI stays responsive
- Logging to `C:\ScriptLog`, comprehensive error handling, enforced administrator rights

---

<div align="center">

[Zurück zur README / Back to README](README.md)

</div>
