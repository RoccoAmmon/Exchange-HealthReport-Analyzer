# Changelog / Änderungsverlauf

Alle nennenswerten Änderungen an diesem Projekt.
Alle Änderungen an diesem Projekt werden in dieser Datei dokumentiert.
Format: [Keep a Changelog](https://keepachangelog.com/de/1.1.0/) · Versionierung: [Semantic Versioning](https://semver.org/lang/de/)

[Deutsch](#-deutsch) · [English](#-english) · [README](README.md)

---

## 🇩🇪 Deutsch

Legende: **Hinzugefügt** = neue Funktion · **Geändert** = Verhaltensänderung · **Behoben** = Fehlerkorrektur · **Sicherheit** = sicherheitsrelevant

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
