#Requires -Version 5.1
# Hinweis: KEIN #Requires -RunAsAdministrator - das Skript erhoeht sich unten
# in "Selbst-Elevation" bei Bedarf selbst per UAC-Abfrage (inkl. Parameter).

<#
.SYNOPSIS
    Exchange HealthReport Analyzer - WPF-GUI zur Analyse und Verwaltung von
    Exchange Managed Availability (Server Health / HealthSets) auf
    Exchange Server 2019 und Exchange Server Subscription Edition (SE).

.DESCRIPTION
    Vollstaendiges GUI-Werkzeug (WPF/XAML) fuer Health-Checks (Managed Availability).
    Funktionen:
      * Initialer Scan via Get-HealthReport (Filter: AlertValue -ne 'Healthy')
      * Deep-Dive Analyse via Get-ServerHealth + passende ActiveMonitoring-Eventlogs
        (Probe-/Monitor-/ResponderResult, ManagedAvailability/Monitoring,
        RecoveryActionResults, Application-Log), inkl. Live-Probe
        (Invoke-MonitoringProbe) als Fallback bei deaktivierten Logs
      * Fehler zuerst: Relevanz-Ranking (Monitor-/Probe-Namen vor HealthSet/AppPool),
        nur Fehler-Eintraege (ResultType 1/4, Level Fehler/Warnung), Infos kompakt
      * Suchfenster (6/12/24/48/72h) in der GUI umschaltbar
      * Admin-Aktionen: Invoke-MonitoringProbe, Add-ServerMonitoringOverride, Quick Fix
      * Selbst-Elevation per UAC-Abfrage inkl. Parameterweitergabe
      * HTML-Report-Export und Mail-Versand
      * Umschaltbare UI-Sprache (DE/EN) zur Laufzeit, Auto-Refresh, akzentuiertes Logging

.PARAMETER TargetServer
    Zielserver fuer alle Abfragen. Standard: $env:COMPUTERNAME.

.PARAMETER LogPath
    Verzeichnis fuer die Logdateien. Standard: C:\ScriptLog

.PARAMETER AutoRefreshMinutes
    Intervall des Auto-Refresh-Timers in Minuten. Standard: 5

.PARAMETER OverrideDays
    Gueltigkeitsdauer eines Monitoring-Overrides in Tagen. Standard: 30

.PARAMETER EventLogHours
    Zeitfenster (Stunden) fuer die Eventlog-Suche der ActiveMonitoring-Logs. Standard: 24
    (in der GUI ueber das Suchfenster neben "Analysieren" umschaltbar: 6/12/24/48/72).

.PARAMETER MaxEventsPerLog
    Maximale Anzahl gelesener Events pro ActiveMonitoring-Log. Standard: 300

.PARAMETER Theme
    Darstellung der Oberflaeche: Light (hell, Standard) oder Dark (dunkel).
    Kann zur Laufzeit im Header umgeschaltet werden.

.EXAMPLE
    .\Exchange-HealthReport-Analyzer.ps1

.EXAMPLE
    .\Exchange-HealthReport-Analyzer.ps1 -TargetServer EX01 -AutoRefreshMinutes 10 -OverrideDays 7

.EXAMPLE
    .\Exchange-HealthReport-Analyzer.ps1 -Theme Dark

.NOTES
    Autor   : Rocco Ammon
    Datum   : 2026-10-01
    Version : 1.1.8
    Hinweis : Muss auf einem Exchange-Server (administrativ) ausgefuehrt werden.
              Geprueft gegen Exchange Server 2019 / Subscription Edition (Managed Availability).
#>
[CmdletBinding()]
param(
    [string] $TargetServer       = $env:COMPUTERNAME,
    [string] $LogPath            = 'C:\ScriptLog',
    [int]    $AutoRefreshMinutes = 5,
    [int]    $OverrideDays       = 30,
    [int]    $EventLogHours      = 24,
    [int]    $MaxEventsPerLog    = 300,
    [ValidateSet('Light', 'Dark')]
    [string] $Theme              = 'Light'
)

#region Selbst-Elevation (Administratorrechte)
# Exchange-Cmdlets, Eventlogs und Dienst-/AppPool-Aktionen brauchen erhoehte Rechte.
# Ohne Adminrechte startet sich das Skript per UAC-Abfrage selbst neu und reicht
# alle Parameter durch (danach endet die nicht erhoehte Instanz per exit).
# Bei Ablehnung des UAC-Dialogs startet die erhoehte Instanz nicht - auch dann endet
# diese Instanz hier, statt kommentarlos weiterzulaufen.
try {
    $elevIdentity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $elevPrincipal = New-Object System.Security.Principal.WindowsPrincipal($elevIdentity)
    if (-not $elevPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $invokedAsScript = ($MyInvocation.InvocationName -ne '.') -and (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) -and (Test-Path -LiteralPath $PSCommandPath)
        if ($invokedAsScript) {
            $elevExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $elevArgs = @(
                '-NoProfile'
                '-ExecutionPolicy Bypass'
                '-STA'
                ('-File "{0}"' -f $PSCommandPath)
                ('-TargetServer "{0}"' -f $TargetServer)
                ('-LogPath "{0}"' -f $LogPath)
                ('-AutoRefreshMinutes {0}' -f $AutoRefreshMinutes)
                ('-OverrideDays {0}' -f $OverrideDays)
                ('-EventLogHours {0}' -f $EventLogHours)
                ('-MaxEventsPerLog {0}' -f $MaxEventsPerLog)
                ('-Theme {0}' -f $Theme)
            )
            try {
                Start-Process -FilePath $elevExe -ArgumentList ($elevArgs -join ' ') -Verb RunAs -ErrorAction Stop
            } catch {
                Write-Host ('Administratorrechte erforderlich. Erhoehter Start abgebrochen: {0}' -f $_.Exception.Message) -ForegroundColor Red
            }
            exit
        } else {
            Write-Host 'Administratorrechte erforderlich. Bitte PowerShell als Administrator starten.' -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host ('Admin-Pruefung fehlgeschlagen: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
}
#endregion

#region Konfiguration / Variablen
$Script:Config = @{
    AppVersion         = '1.1.8'
    LogPath            = $LogPath
    LogFile            = (Join-Path $LogPath ('Exchange-HealthReport-Analyzer_{0:yyyyMMdd}.log' -f (Get-Date)))
    TargetServer       = if ([string]::IsNullOrWhiteSpace($TargetServer)) { $env:COMPUTERNAME } else { $TargetServer }
    AutoRefreshMinutes = $AutoRefreshMinutes
    OverrideDays       = $OverrideDays
    EventLogHours      = $EventLogHours
    MaxEventsPerLog    = $MaxEventsPerLog
    Language           = 'DE'
    Theme              = $Theme
    # Debug-Logs der Managed Availability (Probe-/Monitor-/Responder-Ergebnisse)
    # Hinweis: ProbeResult/MonitorResult/ResponderResult sind auf Produktivservern
    # aus Performance-Gruenden oft deaktiviert (LogIsEnabled=False). Die eigentliche
    # Eskalationsmeldung inkl. letztem Probe-Fehler steht in
    # Microsoft-Exchange-ManagedAvailability/Monitoring - daher wird dieses Log
    # immer mit abgefragt (Best Practice laut Microsoft-Doku).
    MonitoringLogs     = @(
        'Microsoft-Exchange-ActiveMonitoring/ProbeResult',
        'Microsoft-Exchange-ActiveMonitoring/MonitorResult',
        'Microsoft-Exchange-ActiveMonitoring/ResponderResult',
        'Microsoft-Exchange-ManagedAvailability/Monitoring',
        'Microsoft-Exchange-ManagedAvailability/RecoveryActionResults'
    )
    # Reihenfolge: Subscription Edition zuerst, danach die klassische 2010er-Snapin
    ExchangeSnapins    = @(
        'Microsoft.Exchange.Management.PowerShell.SE',
        'Microsoft.Exchange.Management.PowerShell.E2010'
    )
    MailDefaults       = @{
        SmtpServer = 'localhost'
        Port       = 25
        UseSsl     = $false
        From       = ('healthreport@{0}' -f $(if ([string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) { 'contoso.local' } else { $env:USERDNSDOMAIN }))
        To         = ''
        Subject    = ('Exchange Health Report - {0}' -f $TargetServer)
    }
}

# Farbpaletten fuer Hell-/Dunkelmodus. Die Schluessel entsprechen exakt den
# Ressourcennamen im XAML (dort per DynamicResource gebunden), damit die
# Darstellung zur Laufzeit ohne Neustart gewechselt werden kann.
$Script:Themes = @{
    Light = @{
        WindowBg       = '#FFF4F6F8'
        TextFg         = '#FF1F2430'
        PanelBg        = '#FFFFFFFF'
        LineBrush      = '#FFC9D2DC'
        InputBg        = '#FFFFFFFF'
        AccentFg       = '#FF1F3B57'
        HeaderBg       = '#FFE8EDF3'
        GridBg         = '#FFFFFFFF'
        RowBg          = '#FFFFFFFF'
        RowAltBg       = '#FFF6F8FA'
        WarnFg         = '#FFA05A00'
        UnhealthyRowBg = '#FFFDECEA'
        UnhealthyRowFg = '#FF8C1D18'
        DegradedRowBg  = '#FFFFF6E5'
        DegradedRowFg  = '#FF8A5200'
    }
    Dark = @{
        WindowBg       = '#FF1B1B24'
        TextFg         = '#FFE6E6E6'
        PanelBg        = '#FF23232F'
        LineBrush      = '#FF3A3A4A'
        InputBg        = '#FF16161E'
        AccentFg       = '#FF9FD3FF'
        HeaderBg       = '#FF2A2A38'
        GridBg         = '#FF16161E'
        RowBg          = '#FF1F1F2B'
        RowAltBg       = '#FF23232F'
        WarnFg         = '#FFFFC857'
        UnhealthyRowBg = '#FF4A221F'
        UnhealthyRowFg = '#FFFFC9C9'
        DegradedRowBg  = '#FF4A3A1F'
        DegradedRowFg  = '#FFFFE0A3'
    }
}

# Laufzeit-Zustand der Anwendung
$Script:State = @{
    HealthData      = @()    # alle Checks des letzten Scans (inkl. Healthy)
    Unhealthy       = @()    # gefilterte, ungesunde Checks (DataGrid-Quelle)
    Selected        = $null  # aktuell im DataGrid markierte Zeile
    DetailsBySet    = @{}    # HealthSet -> formatierter Detailtext (fuer HTML-Export)
    AnalyseResult   = $null  # letztes Analyseergebnis (Rohobjekt)
    Busy            = $false
    BusyKey         = 'StatusLoading'
    ExchangeLoaded  = $false
    LastScanTime    = $null
    LastStatusKey   = 'StatusReady'
    LastStatusArgs  = @()
}

# UI-Referenzen (x:Name -> Steuerelement) und asynchrone Engine
$Script:Ui               = @{}
$Script:MailUi           = @{}
$Script:MailRecipients   = @()
$Script:Async            = $null
$Script:AutoRefreshTimer = $null
$Script:ExchangeRunspace = $null
$Script:LocalRunspace    = $null

# Bekannte Zuordnung HealthSet -> Dienst/AppPool fuer den Quick Fix
# (Zuordnung fuer Exchange Server 2019 / Subscription Edition; die Schluessel
#  werden in Get-QuickFixTarget zuerst exakt und danach als laengster Teiltreffer geprueft.)
$Script:QuickFixMap = @{
    'ActiveSync'           = @{ Services = @('W3SVC');              AppPools = @('MSExchangeSyncAppPool') }
    'OWA'                  = @{ Services = @('W3SVC');              AppPools = @('MSExchangeOWAAppPool') }
    'ECP'                  = @{ Services = @('W3SVC');              AppPools = @('MSExchangeECPAppPool') }
    'AutoDiscover'         = @{ Services = @('W3SVC');              AppPools = @('MSExchangeAutodiscoverAppPool') }
    'Ews'                  = @{ Services = @('W3SVC');              AppPools = @('MSExchangeServicesAppPool') }
    'OAB'                  = @{ Services = @('W3SVC');              AppPools = @('MSExchangeServicesAppPool') }
    'Mapi'                 = @{ Services = @('MSExchangeRpcClientAccess'); AppPools = @('MSExchangeMapiMailboxAppPool', 'MSExchangeMapiFrontEndAppPool') }
    'Outlook'              = @{ Services = @('MSExchangeRpcClientAccess'); AppPools = @('MSExchangeMapiFrontEndAppPool', 'MSExchangeMapiMailboxAppPool') }
    'Transport'            = @{ Services = @('MSExchangeTransport');                                  AppPools = @() }
    'MailboxTransport'     = @{ Services = @('MSExchangeDelivery', 'MSExchangeSubmission');           AppPools = @() }
    'FrontendTransport'    = @{ Services = @('MSExchangeFrontEndTransport');                          AppPools = @() }
    'Provisioning'         = @{ Services = @('MSExchangeServiceHost');                                AppPools = @() }
    'EventAssistants'      = @{ Services = @('MSExchangeServiceHost');                                AppPools = @() }
    'PushNotifications'    = @{ Services = @('MSExchangePushNotifications');                          AppPools = @() }
    'EDS'                  = @{ Services = @('MSExchangeEdgeSync');                                   AppPools = @() }
    'AD'                   = @{ Services = @('MSExchangeADTopology', 'MSExchangeServiceHost');        AppPools = @() }
    'Search'               = @{ Services = @('MSExchangeFastSearch', 'HostControllerService');        AppPools = @() }
    'Monitoring'           = @{ Services = @('MSExchangeDiagnostics');                                AppPools = @() }
    'Antimalware'          = @{ Services = @('MsMpEng', 'WinDefend');                                 AppPools = @() }
    'IMAP'                 = @{ Services = @('MSExchangeIMAP4', 'MSExchangeIMAP4BE');                 AppPools = @() }
    'POP'                  = @{ Services = @('MSExchangePOP3', 'MSExchangePOP3BE');                   AppPools = @() }
    'MailboxSpace'         = @{ Services = @('MSExchangeIS');                                         AppPools = @() }
    'DatabaseAvailability' = @{ Services = @('MSExchangeRepl', 'MSExchangeIS');                       AppPools = @() }
    'MailboxDatabase'      = @{ Services = @('MSExchangeIS');                                         AppPools = @() }
    'HttpProxy'            = @{ Services = @('MSExchangeServiceHost');                                AppPools = @() }
    'Rest'                 = @{ Services = @('W3SVC');              AppPools = @('MSExchangeRestAppPool') }
}

#endregion

#region Lokalisierung (DE / EN)
$Script:T = @{
    DE = @{
        AppTitle              = 'Exchange HealthReport Analyzer'
        LblServer             = 'Zielserver:'
        LblLanguage           = 'Sprache:'
        LblTheme              = 'Darstellung:'
        ThemeLight            = 'Hell'
        ThemeDark             = 'Dunkel'
        ChkAutoRefresh        = 'Auto-Refresh ({0} Min)'
        LblHours              = 'Suchfenster:'
        BtnScan               = 'Scan starten'
        BtnExportHtml         = 'Als HTML exportieren'
        BtnSendMail           = 'Report per Mail senden'
        GrpUnhealthy          = 'Unhealthy Checks (HealthSets)'
        GrpDetails            = 'Fehlerdetails & Eventlogs'
        BtnAnalyse            = 'Analysieren'
        BtnRetest             = 'Jetzt Re-Testen'
        BtnOverride           = 'Override setzen ({0} Tage)'
        BtnQuickFix           = 'Quick Fix (Dienst/AppPool)'
        BtnClose              = 'Schliessen'
        ColHealthSet          = 'HealthSet'
        ColMonitor            = 'Monitor'
        ColAlert              = 'Status'
        ColChanged            = 'Letzte Aenderung'
        ColTarget             = 'Zielressource'
        StatusReady           = 'Bereit.'
        StatusLoading         = 'Ladevorgang laeuft ...'
        StatusScanning        = 'Health-Checks werden geladen ...'
        StatusAnalyzing       = 'Analysiere HealthSet {0} ...'
        StatusLoadingExchange = 'Exchange-Verwaltung wird initialisiert ...'
        StatusExchangeOk      = 'Exchange-Verwaltung geladen ({0}).'
        StatusExchangeLocal   = 'Exchange-Verwaltung nicht geladen - nur lokale Analysen moeglich.'
        StatusScanDone        = 'Scan abgeschlossen: {0} ungesunde von {1} Checks.'
        StatusAutoRefresh     = 'Auto-Refresh aktiv (alle {0} Min).'
        StatusRetesting       = 'Monitoring-Probes werden neu ausgefuehrt ...'
        StatusOverride        = 'Monitoring-Override wird gesetzt ...'
        StatusQuickFix        = 'Dienst/AppPool wird neu gestartet ...'
        StatusExporting       = 'HTML-Report wird erstellt ...'
        StatusSendingMail     = 'Report wird per E-Mail gesendet ...'
        StatusSelectRow       = 'Bitte zuerst einen Check in der Liste auswaehlen.'
        DetailsPlaceholder    = 'Waehlen Sie einen Check aus und klicken Sie auf "Analysieren", um Fehlerdetails und Eventlogs zu sehen.'
        DetailsTitle          = 'HEALTHSET: {0}'
        DetailsMonitor        = 'Monitor      : {0}'
        DetailsStatus         = 'Status       : {0}'
        DetailsTarget         = 'Ziel         : {0}'
        DetailsLastChange     = 'Letzte Aend. : {0}'
        DetailsCounter        = 'Fehler/Count : {0}'
        DetailsFirstFailed    = 'Erster Fehler : {0}'
        DetailsLastExec       = 'Letzte Ausf. : {0} ({1})'
        DetailsError          = 'Fehler       : {0}'
        DetailsException      = 'Ausnahme     : {0}'
        DetailsDescription    = 'Beschreibung : {0}'
        DetailsProbeHint      = 'Tipp: Zugehoerige Probe manuell starten: Invoke-MonitoringProbe {0}\<ProbeName> -Server {1} | Format-List (Proben via Get-MonitoringItemIdentity -Identity {0} -Server {1} auflisten).'
        DetailsFallbackEvents = 'Neueste Eintraege aus {0} (ohne direkten Monitorbezug, {1}):'
        DetailsDisabledHint   = 'Hinweis: ProbeResult/MonitorResult/ResponderResult sind auf Produktivservern aus Performance-Gruenden oft deaktiviert. Aussagekraeftig ist Microsoft-Exchange-ManagedAvailability/Monitoring (enthaelt den letzten Probe-Fehler).'
        DetailsStale          = 'Status          : Monitorwert ist veraltet (IsStale=True) - Health Manager hat den Monitor seit laengerer Zeit nicht aktualisiert.'
        DetailsExtended       = 'Details        : {0}'
        DetailsProbes         = 'Proben         : {0}'
        DetailsLiveProbe      = 'Live-Probe (direkt ausgefuehrt):'
        DetailsLiveOk         = 'Probe erfolgreich, kein Fehlertext (Monitor ggf. noch nicht zurueckgesetzt).'
        DetailsErrorEvents    = 'Fehler-Eintraege ({0}):'
        DetailsErrorEventsWeak = 'Fehler-Eintraege (HealthSet-weit, {0}):'
        DetailsDupes          = ' ({0}x identisch, neuester gezeigt)'
        DetailsProbeFailed    = 'FEHLER'
        DetailsRunError       = 'Fehler: {0}'
        DetailsTargetInfo     = 'Info-Eintraege zum Ziel {0} ({1}):'
        DetailsHiddenInfo     = '(+ {0} weitere Informations-Eintraege ausgeblendet.)'
        DetailsNoEventsRead   = 'Keine Events lesbar: alle abgefragten Logs sind deaktiviert oder leer im Zeitfenster ({0}h). Siehe Live-Probe oben und Hinweise unten.'
        DetailsProbeHintConcrete = 'Tipp: Probe manuell starten: Invoke-MonitoringProbe {0} -Server {1} | Format-List'
        DetailsEnableLogsHint = 'Tipp: ManagedAvailability-Logs reaktivieren (erhoehtes Aufkommen beachten): wevtutil sl "Microsoft-Exchange-ManagedAvailability/Monitoring" /e:true ; wevtutil sl "Microsoft-Exchange-ActiveMonitoring/ProbeResult" /e:true'
        DetailsEvents         = 'Passende Eventlogs ({0}):'
        DetailsNoEvents       = 'Keine passenden Eventlogs im gewaehlten Zeitfenster gefunden.'
        DetailsErrors         = 'Hinweise/Fehler bei der Analyse:'
        MsgTitle              = 'Exchange HealthReport Analyzer'
        MsgNoSelection        = 'Bitte zuerst einen Check in der Liste auswaehlen.'
        MsgNoData             = 'Es liegen keine Daten vor. Bitte zuerst einen Scan ausfuehren.'
        MsgConfirmOverride    = 'Soll fuer "{0}" ein Monitoring-Override fuer {1} Tage gesetzt werden?' + "`n`n" + 'Der Check wird damit stummgeschaltet (False Positive).'
        MsgOverrideOk         = 'Override wurde gesetzt:' + "`n" + '{0}'
        MsgRetestDone         = 'Re-Test abgeschlossen ({0} Probe(s)):' + "`n" + '{1}'
        MsgQuickFixConfirm    = 'Folgende Komponenten auf {0} neu starten?' + "`n`n" + '{1}'
        MsgQuickFixNone       = 'Aus dem gewaehlten Monitor konnte kein Dienst bzw. AppPool abgeleitet werden.'
        MsgQuickFixDone       = 'Quick Fix abgeschlossen:' + "`n" + '{0}'
        MsgExportOk           = 'HTML-Report wurde gespeichert:' + "`n" + '{0}'
        MsgMailOk             = 'Report wurde an {0} gesendet.'
        MsgMailIncomplete     = 'Bitte Empfaenger (und ggf. Absender) angeben.'
        ErrNoExchange         = 'Die Exchange-Verwaltungsshell ist nicht verfuegbar.' + "`n" + 'Bitte das Skript auf einem Exchange-Server mit installierter Verwaltungstools-Shell ausfuehren.'
        ErrNoServer           = 'Es ist kein Zielserver angegeben.'
        ErrGeneric            = 'Fehler: {0}'
        DlgSaveTitle          = 'HTML-Report speichern'
        DlgHtmlFilter         = 'HTML-Dateien (*.html)|*.html|Alle Dateien (*.*)|*.*'
        MailTitle             = 'Report per E-Mail senden'
        MailSmtp              = 'SMTP-Server:'
        MailPort              = 'Port:'
        MailSsl               = 'SSL/TLS verwenden'
        MailFrom              = 'Absender:'
        MailTo                = 'Empfaenger (durch ; getrennt):'
        MailSubject           = 'Betreff:'
        BtnSend               = 'Senden'
        BtnCancel             = 'Abbrechen'
        HtmlTitle             = 'Exchange Health Report'
        HtmlServer            = 'Server'
        HtmlCreated           = 'Erstellt am'
        HtmlSummary           = 'Zusammenfassung'
        HtmlUnhealthy         = 'Ungesunde Checks'
        HtmlHealthy           = 'Gesunde Checks'
        HtmlTotal             = 'Checks gesamt'
        HtmlDetails           = 'Fehlerdetails und Eventlogs'
        HtmlNoIssues          = 'Es wurden keine ungesunden Checks gefunden.'
        HtmlFooter            = 'Automatisch erstellt durch den Exchange HealthReport Analyzer v{0}'
    }
    EN = @{
        AppTitle              = 'Exchange HealthReport Analyzer'
        LblServer             = 'Target server:'
        LblLanguage           = 'Language:'
        LblTheme              = 'Appearance:'
        ThemeLight            = 'Light'
        ThemeDark             = 'Dark'
        ChkAutoRefresh        = 'Auto-refresh ({0} min)'
        LblHours              = 'Time window:'
        BtnScan               = 'Start scan'
        BtnExportHtml         = 'Export as HTML'
        BtnSendMail           = 'Send report by mail'
        GrpUnhealthy          = 'Unhealthy Checks (HealthSets)'
        GrpDetails            = 'Error details & event logs'
        BtnAnalyse            = 'Analyse'
        BtnRetest             = 'Re-Test now'
        BtnOverride           = 'Set override ({0} days)'
        BtnQuickFix           = 'Quick Fix (service/app pool)'
        BtnClose              = 'Close'
        ColHealthSet          = 'HealthSet'
        ColMonitor            = 'Monitor'
        ColAlert              = 'Status'
        ColChanged            = 'Last change'
        ColTarget             = 'Target resource'
        StatusReady           = 'Ready.'
        StatusLoading         = 'Operation in progress ...'
        StatusScanning        = 'Loading health checks ...'
        StatusAnalyzing       = 'Analysing health set {0} ...'
        StatusLoadingExchange = 'Initialising Exchange management ...'
        StatusExchangeOk      = 'Exchange management loaded ({0}).'
        StatusExchangeLocal   = 'Exchange management not loaded - local analysis only.'
        StatusScanDone        = 'Scan completed: {0} unhealthy of {1} checks.'
        StatusAutoRefresh     = 'Auto-refresh active (every {0} min).'
        StatusRetesting       = 'Re-running monitoring probes ...'
        StatusOverride        = 'Applying monitoring override ...'
        StatusQuickFix        = 'Restarting service/app pool ...'
        StatusExporting       = 'Creating HTML report ...'
        StatusSendingMail     = 'Sending report by e-mail ...'
        StatusSelectRow       = 'Please select a check in the list first.'
        DetailsPlaceholder    = 'Select a check and click "Analyse" to display error details and event logs.'
        DetailsTitle          = 'HEALTH SET: {0}'
        DetailsMonitor        = 'Monitor      : {0}'
        DetailsStatus         = 'Status       : {0}'
        DetailsTarget         = 'Target       : {0}'
        DetailsLastChange     = 'Last change  : {0}'
        DetailsCounter        = 'Failures     : {0}'
        DetailsFirstFailed    = 'First failure : {0}'
        DetailsLastExec       = 'Last run      : {0} ({1})'
        DetailsError          = 'Error         : {0}'
        DetailsException      = 'Exception     : {0}'
        DetailsDescription    = 'Description   : {0}'
        DetailsProbeHint      = 'Tip: run the related probe manually: Invoke-MonitoringProbe {0}\<ProbeName> -Server {1} | Format-List (list probes via Get-MonitoringItemIdentity -Identity {0} -Server {1}).'
        DetailsFallbackEvents = 'Most recent entries from {0} (no direct monitor match, {1}):'
        DetailsDisabledHint   = 'Note: ProbeResult/MonitorResult/ResponderResult are often disabled on production servers for performance reasons. Microsoft-Exchange-ManagedAvailability/Monitoring is authoritative (contains the most recent probe error).'
        DetailsStale          = 'Status          : Monitor value is stale (IsStale=True) - Health Manager has not updated the monitor for a while.'
        DetailsExtended       = 'Details        : {0}'
        DetailsProbes         = 'Probes         : {0}'
        DetailsLiveProbe      = 'Live probe (executed directly):'
        DetailsLiveOk         = 'Probe succeeded, no error text (monitor may not have reset yet).'
        DetailsErrorEvents    = 'Error entries ({0}):'
        DetailsErrorEventsWeak = 'Error entries (health-set-wide, {0}):'
        DetailsDupes          = ' ({0}x identical, newest shown)'
        DetailsProbeFailed    = 'FAILED'
        DetailsRunError       = 'Error: {0}'
        DetailsTargetInfo     = 'Informational entries for target {0} ({1}):'
        DetailsHiddenInfo     = '(+ {0} further informational entries hidden.)'
        DetailsNoEventsRead   = 'No events readable: all queried logs are disabled or empty in the time window ({0}h). See live probe above and hints below.'
        DetailsProbeHintConcrete = 'Tip: run the probe manually: Invoke-MonitoringProbe {0} -Server {1} | Format-List'
        DetailsEnableLogsHint = 'Tip: re-enable ManagedAvailability logs (expect higher volume): wevtutil sl "Microsoft-Exchange-ManagedAvailability/Monitoring" /e:true ; wevtutil sl "Microsoft-Exchange-ActiveMonitoring/ProbeResult" /e:true'
        DetailsEvents         = 'Matching event log entries ({0}):'
        DetailsNoEvents       = 'No matching event log entries found in the selected time frame.'
        DetailsErrors         = 'Warnings/errors during analysis:'
        MsgTitle              = 'Exchange HealthReport Analyzer'
        MsgNoSelection        = 'Please select a check in the list first.'
        MsgNoData             = 'No data available. Please run a scan first.'
        MsgConfirmOverride    = 'Set a monitoring override for "{0}" for {1} days?' + "`n`n" + 'The check will be silenced (false positive).'
        MsgOverrideOk         = 'Override has been applied:' + "`n" + '{0}'
        MsgRetestDone         = 'Re-test completed ({0} probe(s)):' + "`n" + '{1}'
        MsgQuickFixConfirm    = 'Restart the following components on {0}?' + "`n`n" + '{1}'
        MsgQuickFixNone       = 'No service or application pool could be derived from the selected monitor.'
        MsgQuickFixDone       = 'Quick fix completed:' + "`n" + '{0}'
        MsgExportOk           = 'HTML report has been saved:' + "`n" + '{0}'
        MsgMailOk             = 'Report has been sent to {0}.'
        MsgMailIncomplete     = 'Please specify at least the recipient (and sender).'
        ErrNoExchange         = 'Exchange management shell is not available.' + "`n" + 'Please run this script on an Exchange server with the management tools installed.'
        ErrNoServer           = 'No target server specified.'
        ErrGeneric            = 'Error: {0}'
        DlgSaveTitle          = 'Save HTML report'
        DlgHtmlFilter         = 'HTML files (*.html)|*.html|All files (*.*)|*.*'
        MailTitle             = 'Send report by e-mail'
        MailSmtp              = 'SMTP server:'
        MailPort              = 'Port:'
        MailSsl               = 'Use SSL/TLS'
        MailFrom              = 'Sender:'
        MailTo                = 'Recipients (separated by ;):'
        MailSubject           = 'Subject:'
        BtnSend               = 'Send'
        BtnCancel             = 'Cancel'
        HtmlTitle             = 'Exchange Health Report'
        HtmlServer            = 'Server'
        HtmlCreated           = 'Created on'
        HtmlSummary           = 'Summary'
        HtmlUnhealthy         = 'Unhealthy checks'
        HtmlHealthy           = 'Healthy checks'
        HtmlTotal             = 'Total checks'
        HtmlDetails           = 'Error details and event logs'
        HtmlNoIssues          = 'No unhealthy checks were found.'
        HtmlFooter            = 'Automatically generated by Exchange HealthReport Analyzer v{0}'
    }
}

<#
.SYNOPSIS
    Liefert einen lokalisierten Text fuer den angegebenen Schluessel.
#>
function Get-Text {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key
    )
    try {
        $lang = $Script:T[$Script:Config.Language]
        if ($lang -and $lang[$Key]) { return $lang[$Key] }
        if ($Script:T['EN'][$Key]) { return $Script:T['EN'][$Key] }
        return $Key
    } catch {
        return $Key
    }
}

<#
.SYNOPSIS
    Liefert einen lokalisierten Text und formatiert ihn mit den uebergebenen Argumenten.
#>
function Get-TextF {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )
    try {
        $template = Get-Text -Key $Key
        if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return $template }
        return ($template -f $Arguments)
    } catch {
        return (Get-Text -Key $Key)
    }
}
#endregion

#region Protokollierung / Status
<#
.SYNOPSIS
    Schreibt eine Zeile in die Logdatei (Datei wird bei Bedarf angelegt).
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $Script:Config.LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Logging darf die GUI niemals unterbrechen
    }
}

<#
.SYNOPSIS
    Zeigt eine Statusmeldung in der Fussleiste an.
#>
function Set-Status {
    [CmdletBinding()]
    param(
        [string]$Key = 'StatusReady',
        [object[]]$Arguments = @()
    )
    try {
        $Script:State.LastStatusKey = $Key
        $Script:State.LastStatusArgs = $Arguments
        $text = Get-TextF -Key $Key -Arguments $Arguments
        if ($Script:Ui['TxtStatus']) {
            $Script:Ui['TxtStatus'].Text = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $text
        }
    } catch {
        Write-Log -Message ('Set-Status: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}

<#
.SYNOPSIS
    Universelle Fehleranzeige (MessageBox) inkl. Logging.
#>
function Show-Error {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'ERROR'
    )
    try {
        Write-Log -Message $Message -Level $Level
        if ($Script:Ui['TxtStatus']) {
            $Script:Ui['TxtStatus'].Text = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
        }
        [void][System.Windows.MessageBox]::Show($Message, (Get-Text 'MsgTitle'), 'OK', 'Error')
    } catch {
        Write-Host $Message -ForegroundColor Red
    }
}

<#
.SYNOPSIS
    Schaltet die GUI in den "Beschaeftigt"-Modus (Ladeindikator, Buttons sperren).
#>
function Set-Busy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Active,
        [string]$TextKey = 'StatusLoading'
    )
    try {
        $Script:State.Busy = $Active
        if ($Active) { $Script:State.BusyKey = $TextKey }
        foreach ($name in @('BtnScan', 'BtnExportHtml', 'BtnSendMail', 'BtnAnalyse', 'BtnRetest', 'BtnOverride', 'BtnQuickFix', 'CmbHours')) {
            if ($Script:Ui[$name]) { $Script:Ui[$name].IsEnabled = (-not $Active) }
        }
        if ($Script:Ui['TxtBusy']) {
            $Script:Ui['TxtBusy'].Text = if ($Active) { Get-Text -Key $TextKey } else { '' }
        }
        if ($Script:Ui['PrgBusy']) {
            $Script:Ui['PrgBusy'].Visibility = if ($Active) { 'Visible' } else { 'Collapsed' }
            $Script:Ui['PrgBusy'].IsIndeterminate = $Active
        }
        if ($Active) { Set-Status -Key $TextKey }
    } catch {
        Write-Log -Message ('Set-Busy: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}
#endregion

#region Allgemeine Hilfsfunktionen
<#
.SYNOPSIS
    Prueft die Administratorrechte und liefert $true/$false.
#>
function Test-Administrator {
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Log -Message ('Test-Administrator: {0}' -f $_.Exception.Message) -Level 'WARN'
        return $false
    }
}

<#
.SYNOPSIS
    Laedt die fuer WPF benoetigten .NET-Assemblies (idempotent).
#>
function Initialize-WpfAssemblies {
    [CmdletBinding()]
    param()
    try {
        foreach ($assemblyName in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')) {
            try {
                Add-Type -AssemblyName $assemblyName -ErrorAction Stop
            } catch {
                Write-Log -Message ('WPF-Assembly nicht ladbar: {0} ({1})' -f $assemblyName, $_.Exception.Message) -Level 'WARN'
            }
        }
    } catch {
        Write-Log -Message ('Initialize-WpfAssemblies: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}

<#
.SYNOPSIS
    Prueft, ob der aktuelle Thread im STA-Modus laeuft (WPF-Voraussetzung).
    Bei MTA wird das Skript automatisch in einer STA-Instanz neu gestartet.
#>
function Test-StaApartment {
    [CmdletBinding()]
    param()
    try {
        $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
        if ($apartment -eq [System.Threading.ApartmentState]::STA) { return $true }

        Write-Log -Message ('MTA-Apartment erkannt ({0}) - Neustart in STA erforderlich.' -f $apartment) -Level 'WARN'
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $exe)) { return $false }

        # Argumentliste fuer die STA-Neuinstanz (Pfade werden gequotet)
        $arguments = @(
            '-NoProfile'
            '-ExecutionPolicy Bypass'
            '-STA'
            ('-File "{0}"' -f $PSCommandPath)
            ('-TargetServer "{0}"' -f $Script:Config.TargetServer)
            ('-LogPath "{0}"' -f $Script:Config.LogPath)
            ('-AutoRefreshMinutes {0}' -f $Script:Config.AutoRefreshMinutes)
            ('-OverrideDays {0}' -f $Script:Config.OverrideDays)
            ('-EventLogHours {0}' -f $Script:Config.EventLogHours)
            ('-MaxEventsPerLog {0}' -f $Script:Config.MaxEventsPerLog)
            ('-Theme {0}' -f $Script:Config.Theme)
        )
        Start-Process -FilePath $exe -ArgumentList ($arguments -join ' ')
        return $false
    } catch {
        Write-Log -Message ('Test-StaApartment: {0}' -f $_.Exception.Message) -Level 'ERROR'
        return $false
    }
}

<#
.SYNOPSIS
    Erzeugt (falls noetig) das Logverzeichnis.
#>
function Initialize-LogDirectory {
    try {
        if (-not (Test-Path -LiteralPath $Script:Config.LogPath)) {
            [void](New-Item -Path $Script:Config.LogPath -ItemType Directory -Force -ErrorAction Stop)
        }
    } catch {
        Write-Host ('Logverzeichnis konnte nicht erstellt werden: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

<#
.SYNOPSIS
    Liefert den aktuell konfigurierten Zielserver (aus dem Eingabefeld, sonst Konfiguration).
#>
function Get-TargetServer {
    try {
        if ($Script:Ui['TxtServer'] -and -not [string]::IsNullOrWhiteSpace($Script:Ui['TxtServer'].Text)) {
            return $Script:Ui['TxtServer'].Text.Trim()
        }
        return $Script:Config.TargetServer
    } catch {
        return $Script:Config.TargetServer
    }
}

<#
.SYNOPSIS
    Leitet aus HealthSet/Monitor/Zielressource die betroffenen Dienste und AppPools ab.
#>
function Get-QuickFixTarget {
    [CmdletBinding()]
    param(
        [string]$HealthSet,
        [string]$Monitor,
        [string]$TargetResource
    )
    $result = @{ Services = @(); AppPools = @() }
    try {
        $map = $null
        if ($HealthSet) {
            # 1) Exakter Treffer hat Vorrang (z. B. FrontendTransport vs. Transport)
            if ($Script:QuickFixMap.ContainsKey($HealthSet)) {
                $map = $Script:QuickFixMap[$HealthSet]
            } else {
                # 2) Sonst gewinnt der laengste (spezifischste) Teiltreffer
                foreach ($key in @($Script:QuickFixMap.Keys | Sort-Object -Property Length -Descending)) {
                    if ($HealthSet -like ('*{0}*' -f $key)) { $map = $Script:QuickFixMap[$key]; break }
                }
            }
        }
        if ($map) {
            $result.Services  = @($map.Services)
            $result.AppPools  = @($map.AppPools)
        }

        # Zielressource auswerten (bei IIS-basierten Probes steht hier oft der AppPool-Name)
        if ($TargetResource -and $TargetResource -ne '') {
            if ($TargetResource -match 'AppPool') {
                if ($result.AppPools -notcontains $TargetResource) { $result.AppPools += $TargetResource }
            } elseif ($TargetResource -match '^(MSExchange|W3SVC|HostController|MsMpEng|Netlogon|WinRM|NetTCP)' -and $result.Services -notcontains $TargetResource) {
                # Nur echte Dienstnamen uebernehmen (AppPool-Werte sind ausgeschlossen)
                $result.Services += $TargetResource
            }
        }

        # HealthSet selbst als Dienst/AppPool-Kandidat pruefen
        if ($Monitor) {
            $explicitX = 'MSExchange'
            if ($result.AppPools.Count -eq 0 -and $result.Services.Count -eq 0 -and $Monitor -match $explicitX) {
                $result.Services += $Monitor
            }
        }
    } catch {
        Write-Log -Message ('Get-QuickFixTarget: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
    return $result
}

<#
.SYNOPSIS
    Normalisiert AlertValue-Werte (Enum/String) auf einen Vergleichstext.
#>
function Get-AlertText {
    param([object]$Value)
    try {
        if ($null -eq $Value) { return 'Unknown' }
        if ($Value -is [string]) { return $Value }
        return [string]$Value
    } catch {
        return 'Unknown'
    }
}
#endregion

#region WPF-XAML (Hauptfenster)
# Das komplette Layout wird als XAML-String geladen. Alle Bereiche nutzen
# dynamische Container (Grid mit *, GridSplitter, WrapPanel), damit das Fenster
# frei skaliert/minimiert/maximiert werden kann und Inhalte den Platz fuellen.
$Script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Exchange HealthReport Analyzer"
        Height="880" Width="1360" MinHeight="620" MinWidth="1020"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip"
        Background="{DynamicResource WindowBg}"
        Foreground="{DynamicResource TextFg}"
        FontFamily="Segoe UI" FontSize="13">
    <Window.Resources>
        <!-- Farbwerte = Palette "Light" (Standard). Zur Laufzeit ersetzt Set-UiTheme
             diese Pinsel durch die Palette "Dark" (dynamische Ressourcen). -->
        <SolidColorBrush x:Key="WindowBg"       Color="#FFF4F6F8"/>
        <SolidColorBrush x:Key="TextFg"         Color="#FF1F2430"/>
        <SolidColorBrush x:Key="PanelBg"        Color="#FFFFFFFF"/>
        <SolidColorBrush x:Key="LineBrush"      Color="#FFC9D2DC"/>
        <SolidColorBrush x:Key="InputBg"        Color="#FFFFFFFF"/>
        <SolidColorBrush x:Key="AccentFg"       Color="#FF1F3B57"/>
        <SolidColorBrush x:Key="HeaderBg"       Color="#FFE8EDF3"/>
        <SolidColorBrush x:Key="GridBg"         Color="#FFFFFFFF"/>
        <SolidColorBrush x:Key="RowBg"          Color="#FFFFFFFF"/>
        <SolidColorBrush x:Key="RowAltBg"       Color="#FFF6F8FA"/>
        <SolidColorBrush x:Key="WarnFg"         Color="#FFA05A00"/>
        <SolidColorBrush x:Key="UnhealthyRowBg" Color="#FFFDECEA"/>
        <SolidColorBrush x:Key="UnhealthyRowFg" Color="#FF8C1D18"/>
        <SolidColorBrush x:Key="DegradedRowBg"  Color="#FFFFF6E5"/>
        <SolidColorBrush x:Key="DegradedRowFg"  Color="#FF8A5200"/>

        <Style x:Key="ToolButton" TargetType="Button">
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="MinWidth" Value="140"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Background" Value="#FF2D7DD2"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <Style x:Key="PanelBorder" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource PanelBg}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="6"/>
            <Setter Property="Padding" Value="12,10"/>
        </Style>

        <!-- Eigene Vorlagen fuer ComboBox/ComboBoxItem/CheckBox: die WPF-Standard-
             vorlagen ignorieren Background/Foreground und zeichnen einen hellen
             Systemverlauf - im Dunkelmodus waere die Beschriftung unlesbar. -->
        <Style x:Key="ThemedCombo" TargetType="ComboBox">
            <Setter Property="Background" Value="{DynamicResource InputBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextFg}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                                          Background="{TemplateBinding Background}"
                                          Foreground="{TemplateBinding Foreground}"
                                          BorderBrush="{TemplateBinding BorderBrush}"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="Chrome" CornerRadius="3" BorderThickness="1"
                                                Background="{TemplateBinding Background}"
                                                BorderBrush="{TemplateBinding BorderBrush}">
                                            <Path x:Name="Arrow" HorizontalAlignment="Right" VerticalAlignment="Center"
                                                  Margin="0,0,8,0" Data="M 0 0 L 4 4 L 8 0 Z"
                                                  Fill="{TemplateBinding Foreground}"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="Chrome" Property="Opacity" Value="0.85"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Margin="8,4,24,4" VerticalAlignment="Center" HorizontalAlignment="Left"
                                              IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" PopupAnimation="Slide"
                                   IsOpen="{TemplateBinding IsDropDownOpen}">
                                <Border CornerRadius="3" BorderThickness="1"
                                        MinWidth="{TemplateBinding ActualWidth}"
                                        MaxHeight="{TemplateBinding MaxDropDownHeight}"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding BorderBrush}">
                                    <ScrollViewer>
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.6"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="{DynamicResource InputBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextFg}"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBorder" Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <!-- Halbtransparente Overlays wirken in beiden Darstellungen -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="#332D7DD2"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="#662D7DD2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource TextFg}"/>
            <Setter Property="Background" Value="{DynamicResource InputBg}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" Background="Transparent">
                            <Border x:Name="Box" Width="16" Height="16" CornerRadius="3" Margin="0,0,8,0"
                                    VerticalAlignment="Center" BorderThickness="1"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}">
                                <Path x:Name="Check" Visibility="Collapsed" Data="M 2,6 L 5.5,9.5 L 12,3"
                                      Stroke="{TemplateBinding Foreground}" StrokeThickness="2"/>
                            </Border>
                            <ContentPresenter VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="#FF2D7DD2"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="#FF2D7DD2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="{DynamicResource AccentFg}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
            <Setter Property="Padding" Value="8"/>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource InputBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextFg}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Kopfzeile: Zielserver, Sprachumschalter, Darstellung (Hell/Dunkel), Auto-Refresh -->
        <Border x:Name="HeaderBorder" Grid.Row="0" Style="{StaticResource PanelBorder}">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*" MinWidth="180"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="LblServer" Grid.Column="0" VerticalAlignment="Center" Margin="0,0,8,0" Text="Target server:"/>
                <TextBox x:Name="TxtServer" Grid.Column="1" Height="28" Padding="6,3" VerticalContentAlignment="Center"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
                    <TextBlock x:Name="LblLanguage" VerticalAlignment="Center" Margin="0,0,8,0" Text="Language:"/>
                    <ComboBox x:Name="CmbLanguage" Width="90" Height="28" SelectedIndex="0" Style="{StaticResource ThemedCombo}">
                        <ComboBoxItem Content="DE"/>
                        <ComboBoxItem Content="EN"/>
                    </ComboBox>
                </StackPanel>
                <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
                    <TextBlock x:Name="LblTheme" VerticalAlignment="Center" Margin="0,0,8,0" Text="Appearance:"/>
                    <ComboBox x:Name="CmbTheme" Width="105" Height="28" SelectedIndex="0" Style="{StaticResource ThemedCombo}">
                        <ComboBoxItem Content="Light"/>
                        <ComboBoxItem Content="Dark"/>
                    </ComboBox>
                </StackPanel>
                <CheckBox x:Name="ChkAutoRefresh" Grid.Column="4" VerticalAlignment="Center" Margin="20,0,0,0" Content="Auto-Refresh"/>
            </Grid>
        </Border>

        <!-- Aktionsleiste (Toolbar) -->
        <Border x:Name="ToolbarBorder" Grid.Row="1" Style="{StaticResource PanelBorder}" Margin="0,8,0,0">
            <DockPanel LastChildFill="True">
                <WrapPanel DockPanel.Dock="Left" Orientation="Horizontal">
                    <Button x:Name="BtnScan" Style="{StaticResource ToolButton}" Content="Start scan"/>
                    <Button x:Name="BtnExportHtml" Style="{StaticResource ToolButton}" Content="Export as HTML" Background="#FF3E8E5A"/>
                    <Button x:Name="BtnSendMail" Style="{StaticResource ToolButton}" Content="Send report" Background="#FF7A5BD2"/>
                </WrapPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Right">
                    <TextBlock x:Name="TxtBusy" VerticalAlignment="Center" Foreground="{DynamicResource WarnFg}" Margin="0,0,10,0" Text=""/>
                    <ProgressBar x:Name="PrgBusy" Width="120" Height="8" Visibility="Collapsed"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- Hauptbereich: Liste links, Details rechts (frei skalierbar per Splitter) -->
        <Grid Grid.Row="2" Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.5*" MinWidth="400"/>
                <ColumnDefinition Width="6" />
                <ColumnDefinition Width="1*" MinWidth="320"/>
            </Grid.ColumnDefinitions>

            <GroupBox x:Name="GrpUnhealthy" Grid.Column="0" Header="Unhealthy Checks">
                <DataGrid x:Name="DgUnhealthy" AutoGenerateColumns="False" IsReadOnly="True"
                          SelectionMode="Single" SelectionUnit="FullRow" HeadersVisibility="Column"
                          GridLinesVisibility="Horizontal" CanUserAddRows="False" CanUserDeleteRows="False"
                          Background="{DynamicResource GridBg}" RowBackground="{DynamicResource RowBg}"
                          AlternatingRowBackground="{DynamicResource RowAltBg}"
                          HorizontalGridLinesBrush="{DynamicResource LineBrush}"
                          Foreground="{DynamicResource TextFg}" BorderThickness="0">
                    <!-- Kopfzeilen- und Zeilenstil (inkl. Rot/Gelb-Trigger) werden
                         von Set-UiTheme passend zur aktiven Palette erzeugt. -->
                    <DataGrid.Columns>
                        <DataGridTextColumn Binding="{Binding HealthSet}" Width="1.1*"/>
                        <DataGridTextColumn Binding="{Binding Monitor}" Width="1.5*"/>
                        <DataGridTextColumn Binding="{Binding AlertValue}" Width="0.8*"/>
                        <DataGridTextColumn Binding="{Binding LastTransitionTime}" Width="1*"/>
                        <DataGridTextColumn Binding="{Binding TargetResource}" Width="1.1*"/>
                    </DataGrid.Columns>
                </DataGrid>
            </GroupBox>

            <GridSplitter Grid.Column="1" Width="6" HorizontalAlignment="Stretch" VerticalAlignment="Stretch"
                          Background="Transparent" ResizeBehavior="PreviousAndNext" ResizeDirection="Columns"/>

            <GroupBox x:Name="GrpDetails" Grid.Column="2" Header="Details">
                <TextBox x:Name="TxtDetails" AcceptsReturn="True" TextWrapping="Wrap" IsReadOnly="True"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         FontFamily="Consolas" FontSize="12" Padding="8"/>
            </GroupBox>
        </Grid>

        <!-- Admin-Aktionen -->
        <Border x:Name="ActionBorder" Grid.Row="3" Style="{StaticResource PanelBorder}" Margin="0,8,0,0">
            <WrapPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnAnalyse" Style="{StaticResource ToolButton}" Content="Analyse" Background="#FF2D7DD2"/>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,8,0">
                    <TextBlock x:Name="LblHours" VerticalAlignment="Center" Margin="0,0,8,0" Text="Time window:"/>
                    <ComboBox x:Name="CmbHours" Width="95" Height="28" SelectedIndex="2" Style="{StaticResource ThemedCombo}" ToolTip="Eventlog-Suchfenster in Stunden">
                        <ComboBoxItem Content="6 h"/>
                        <ComboBoxItem Content="12 h"/>
                        <ComboBoxItem Content="24 h"/>
                        <ComboBoxItem Content="48 h"/>
                        <ComboBoxItem Content="72 h"/>
                    </ComboBox>
                </StackPanel>
                <Button x:Name="BtnRetest" Style="{StaticResource ToolButton}" Content="Re-Test" Background="#FFC98A21"/>
                <Button x:Name="BtnOverride" Style="{StaticResource ToolButton}" Content="Override" Background="#FFB04A4A"/>
                <Button x:Name="BtnQuickFix" Style="{StaticResource ToolButton}" Content="Quick Fix" Background="#FF3E8E5A"/>
            </WrapPanel>
        </Border>

        <!-- Statusleiste -->
        <Border x:Name="StatusBorder" Grid.Row="4" Style="{StaticResource PanelBorder}" Margin="0,8,0,0" Padding="12,6">
            <DockPanel LastChildFill="True">
                <TextBlock x:Name="TxtRightInfo" DockPanel.Dock="Right" Foreground="{DynamicResource AccentFg}" Margin="12,0,0,0" Text=""/>
                <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Text="Ready."/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
'@
#endregion

#region WPF-XAML (Mail-Dialog)
# Kleines Popup zum Versenden des HTML-Reports. Platzhalter {{...}} werden zur
# Laufzeit durch die lokalisierten Texte ersetzt.
$Script:MailXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="{{TITLE}}" Height="360" Width="620"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="{{BG}}" Foreground="{{FG}}" FontFamily="Segoe UI" FontSize="13">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="80"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Row="0" Grid.Column="0" Text="{{LBL_SMTP}}" VerticalAlignment="Center" Margin="0,0,8,8"/>
        <TextBox   Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="3" x:Name="TxtSmtp" Height="26" Margin="0,0,0,8" Padding="6,3" Background="{{INPUT}}" Foreground="{{FG}}" BorderBrush="{{LINE}}"/>

        <TextBlock Grid.Row="1" Grid.Column="0" Text="{{LBL_PORT}}" VerticalAlignment="Center" Margin="0,0,8,8"/>
        <TextBox   Grid.Row="1" Grid.Column="1" x:Name="TxtPort" Height="26" Margin="0,0,16,8" Padding="6,3" Background="{{INPUT}}" Foreground="{{FG}}" BorderBrush="{{LINE}}"/>
        <CheckBox  Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" x:Name="ChkSsl" Content="{{LBL_SSL}}" VerticalAlignment="Center" Margin="0,0,0,8"/>

        <TextBlock Grid.Row="2" Grid.Column="0" Text="{{LBL_FROM}}" VerticalAlignment="Center" Margin="0,0,8,8"/>
        <TextBox   Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="3" x:Name="TxtFrom" Height="26" Margin="0,0,0,8" Padding="6,3" Background="{{INPUT}}" Foreground="{{FG}}" BorderBrush="{{LINE}}"/>

        <TextBlock Grid.Row="3" Grid.Column="0" Text="{{LBL_TO}}" VerticalAlignment="Center" Margin="0,0,8,8"/>
        <TextBox   Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="3" x:Name="TxtTo" Height="26" Margin="0,0,0,8" Padding="6,3" Background="{{INPUT}}" Foreground="{{FG}}" BorderBrush="{{LINE}}"/>

        <TextBlock Grid.Row="4" Grid.Column="0" Text="{{LBL_SUBJECT}}" VerticalAlignment="Top" Margin="0,6,8,8"/>
        <TextBox   Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="3" x:Name="TxtSubject" Height="26" VerticalAlignment="Top" Padding="6,3" Background="{{INPUT}}" Foreground="{{FG}}" BorderBrush="{{LINE}}"/>

        <StackPanel Grid.Row="5" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnSend" Content="{{BTN_SEND}}" Width="120" Height="30" Margin="0,0,8,0" Background="#FF3E8E5A" Foreground="White" BorderThickness="0"/>
            <Button x:Name="BtnCancel" Content="{{BTN_CANCEL}}" Width="120" Height="30" Background="#FF50506A" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@
#endregion

#region UI-Aufbau und Sprachumschaltung
<#
.SYNOPSIS
    Erstellt das Hauptfenster aus XAML, verdrahtet alle Events und zeigt es modal an.
#>
function Show-MainWindow {
    [CmdletBinding()]
    param()
    try {
        Initialize-WpfAssemblies

        $reader = New-Object System.Xml.XmlNodeReader ([xml]$Script:MainXaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        # Steuerelemente ueber x:Name einsammeln
        $names = @(
            'LblServer', 'TxtServer', 'LblLanguage', 'CmbLanguage', 'LblTheme', 'CmbTheme', 'ChkAutoRefresh',
            'BtnScan', 'BtnExportHtml', 'BtnSendMail', 'TxtBusy', 'PrgBusy',
            'GrpUnhealthy', 'DgUnhealthy', 'GrpDetails', 'TxtDetails',
            'BtnAnalyse', 'BtnRetest', 'BtnOverride', 'BtnQuickFix',
            'LblHours', 'CmbHours',
            'TxtStatus', 'TxtRightInfo',
            'HeaderBorder', 'ToolbarBorder', 'ActionBorder', 'StatusBorder'
        )
        foreach ($name in $names) {
            $Script:Ui[$name] = $window.FindName($name)
        }
        $Script:Ui['Window'] = $window

        # Initialwerte
        $Script:Ui['TxtServer'].Text = $Script:Config.TargetServer
        $Script:Ui['TxtDetails'].Text = Get-Text -Key 'DetailsPlaceholder'
        $Script:Ui['DgUnhealthy'].ItemsSource = $null
        # Suchfenster-Vorauswahl aus der Konfiguration (-EventLogHours)
        try {
            $hoursIndex = @('6', '12', '24', '48', '72').IndexOf([string]$Script:Config.EventLogHours)
            $Script:Ui['CmbHours'].SelectedIndex = $(if ($hoursIndex -ge 0) { $hoursIndex } else { 2 })
        } catch { }

        Register-UiEvents -Window $window
        Set-UiTheme -Theme $Script:Config.Theme
        Set-UiLanguage -Language $Script:Config.Language

        Write-Log -Message ('Hauptfenster geladen (Darstellung: {0}).' -f $Script:Config.Theme)
        [void]$window.ShowDialog()
    } catch {
        Write-Log -Message ('Show-MainWindow: {0}' -f $_.Exception.Message) -Level 'ERROR'
        throw
    }
}

<#
.SYNOPSIS
    Registriert alle Event-Handler des Hauptfensters.
#>
function Register-UiEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Windows.Window]$Window)
    try {
        $ui = $Script:Ui

        # Beim Laden: Sprache setzen und Exchange-Verwaltung initialisieren
        $Window.Add_Loaded({
            try {
                Set-UiLanguage -Language $Script:Config.Language
                Start-ExchangeInitialization
            } catch {
                Write-Log -Message ('Loaded-Event: {0}' -f $_.Exception.Message) -Level 'ERROR'
            }
        })

        # Sprache umschalten (zur Laufzeit)
        $ui['CmbLanguage'].Add_SelectionChanged({
            try {
                $item = $Script:Ui['CmbLanguage'].SelectedItem
                if ($item -and $item.Content) { Set-UiLanguage -Language ([string]$item.Content) }
            } catch {
                Write-Log -Message ('Sprachwechsel: {0}' -f $_.Exception.Message) -Level 'WARN'

            }
        })

        # Darstellung umschalten (Hell/Dunkel, zur Laufzeit)
        $ui['CmbTheme'].Add_SelectionChanged({
            try {
                $index = $Script:Ui['CmbTheme'].SelectedIndex
                Set-UiTheme -Theme $(if ($index -eq 1) { 'Dark' } else { 'Light' })
            } catch {
                Write-Log -Message ('Darstellungswechsel: {0}' -f $_.Exception.Message) -Level 'WARN'
            }
        })

        # Suchfenster umschalten (Eventlog-Zeitraum fuer "Analysieren")
        $ui['CmbHours'].Add_SelectionChanged({
            try {
                $item = $Script:Ui['CmbHours'].SelectedItem
                if ($item -and $item.Content) {
                    $digits = ([string]$item.Content) -replace '[^0-9]', ''
                    if ($digits -match '^[0-9]+$') {
                        $Script:Config.EventLogHours = [Math]::Max(1, [int]$digits)
                        Write-Log -Message ('Suchfenster geaendert: {0}h.' -f $Script:Config.EventLogHours) -Level 'DEBUG'
                    }
                }
            } catch {
                Write-Log -Message ('Suchfensterwechsel: {0}' -f $_.Exception.Message) -Level 'WARN'
            }
        })

        # Auto-Refresh aktivieren/deaktivieren
        $ui['ChkAutoRefresh'].Add_Checked({ try { Update-AutoRefreshTimer } catch { Write-Log -Message $_.Exception.Message -Level 'WARN' } })
        $ui['ChkAutoRefresh'].Add_Unchecked({ try { Update-AutoRefreshTimer } catch { Write-Log -Message $_.Exception.Message -Level 'WARN' } })

        # Toolbar
        $ui['BtnScan'].Add_Click({ try { Start-HealthScan } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } })
        $ui['BtnExportHtml'].Add_Click({ try { Export-HtmlReportInteractive } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } })
        $ui['BtnSendMail'].Add_Click({ try { Show-MailDialog } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } })

        # Admin-Aktionen
        $ui['BtnAnalyse'].Add_Click({ try { Invoke-DeepDive } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } })
        $ui['BtnRetest'].Add_Click({ try { Invoke-ReTest } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } })
        $ui['BtnOverride'].Add_Click({ try { Invoke-MonitoringOverride } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } })
        $ui['BtnQuickFix'].Add_Click({ try { Invoke-QuickFix } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } })

        # Auswahl im DataGrid merken
        $ui['DgUnhealthy'].Add_SelectionChanged({
            try {
                $Script:State.Selected = $Script:Ui['DgUnhealthy'].SelectedItem
            } catch {
                Write-Log -Message ('SelectionChanged: {0}' -f $_.Exception.Message) -Level 'WARN'
            }
        })

        # Aufraeumen beim Schliessen (Timer und Runspaces beenden)
        $Window.Add_Closed({
            try {
                Close-AsyncTasks
                Close-Runspaces
                Write-Log -Message 'Anwendung beendet.'
            } catch {
                Write-Log -Message ('Closed-Event: {0}' -f $_.Exception.Message) -Level 'WARN'
            }
        })
    } catch {
        Write-Log -Message ('Register-UiEvents: {0}' -f $_.Exception.Message) -Level 'ERROR'
        throw
    }
}

<#
.SYNOPSIS
    Aktualisiert alle UI-Texte in der aktuell gewaehlten Sprache (DE/EN).
#>
function Set-UiLanguage {
    [CmdletBinding()]
    param([string]$Language)
    try {
        if (-not [string]::IsNullOrWhiteSpace($Language)) { $Script:Config.Language = $Language }
        $ui = $Script:Ui
        if (-not $ui['Window']) { return }

        $ui['Window'].Title        = '{0} v{1}' -f (Get-Text -Key 'AppTitle'), $Script:Config.AppVersion
        $ui['LblServer'].Text      = Get-Text -Key 'LblServer'
        $ui['LblLanguage'].Text    = Get-Text -Key 'LblLanguage'
        $ui['ChkAutoRefresh'].Content = Get-TextF -Key 'ChkAutoRefresh' -Arguments @($Script:Config.AutoRefreshMinutes)
        $ui['BtnScan'].Content     = Get-Text -Key 'BtnScan'
        $ui['BtnExportHtml'].Content = Get-Text -Key 'BtnExportHtml'
        $ui['BtnSendMail'].Content = Get-Text -Key 'BtnSendMail'
        $ui['BtnAnalyse'].Content  = Get-Text -Key 'BtnAnalyse'
        $ui['LblHours'].Text       = Get-Text -Key 'LblHours'
        $ui['BtnRetest'].Content   = Get-Text -Key 'BtnRetest'
        $ui['BtnOverride'].Content = Get-TextF -Key 'BtnOverride' -Arguments @($Script:Config.OverrideDays)
        $ui['BtnQuickFix'].Content = Get-Text -Key 'BtnQuickFix'
        $ui['GrpUnhealthy'].Header = Get-Text -Key 'GrpUnhealthy'
        $ui['GrpDetails'].Header   = Get-Text -Key 'GrpDetails'
        $ui['TxtServer'].ToolTip   = Get-Text -Key 'LblServer'
        $ui['TxtRightInfo'].Text   = 'Server: {0}' -f (Get-TargetServer)

        # DataGrid-Spaltenkoepfe (Index entspricht der XAML-Reihenfolge)
        $columnKeys = @('ColHealthSet', 'ColMonitor', 'ColAlert', 'ColChanged', 'ColTarget')
        $grid = $ui['DgUnhealthy']
        for ($i = 0; $i -lt $columnKeys.Count -and $i -lt $grid.Columns.Count; $i++) {
            $grid.Columns[$i].Header = Get-Text -Key $columnKeys[$i]
        }

        # Detailbereich neu beschriften (bereits analysierte Daten bleiben erhalten)
        if ($Script:State.AnalyseResult) {
            Show-AnalyseResult -Result $Script:State.AnalyseResult
        } elseif ([string]::IsNullOrWhiteSpace($ui['TxtDetails'].Text)) {
            $ui['TxtDetails'].Text = Get-Text -Key 'DetailsPlaceholder'
        }

        # Texte des Darstellungs-Umschalters
        $ui['LblTheme'].Text = Get-Text -Key 'LblTheme'
        if ($ui['CmbTheme']) {
            if ($ui['CmbTheme'].Items.Count -gt 0) { $ui['CmbTheme'].Items[0].Content = Get-Text -Key 'ThemeLight' }
            if ($ui['CmbTheme'].Items.Count -gt 1) { $ui['CmbTheme'].Items[1].Content = Get-Text -Key 'ThemeDark' }
        }

        Set-Status -Key $Script:State.LastStatusKey -Arguments $Script:State.LastStatusArgs
        if ($Script:State.Busy) { Set-Busy -Active $true -TextKey $Script:State.BusyKey }
        Write-Log -Message ('UI-Sprache: {0}' -f $Script:Config.Language) -Level 'DEBUG'
    } catch {
        Write-Log -Message ('Set-UiLanguage: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}

<#
.SYNOPSIS
    Liefert einen Farbwert (ARGB-String) aus der aktiven Farbpalette.
#>
function Get-ThemeColor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    try {
        $palette = $Script:Themes[$Script:Config.Theme]
        if ($palette -and $palette[$Key]) { return [string]$palette[$Key] }
        return [string]$Script:Themes['Light'][$Key]
    } catch {
        return '#FF000000'
    }
}

<#
.SYNOPSIS
    Erzeugt den Kopfzeilen- bzw. Zeilenstil des DataGrids aus der aktiven Palette.
.DESCRIPTION
    Die Styles werden zur Laufzeit neu erzeugt, damit auch die DataTrigger
    (ungesunde = rot, degradierte = gelb) die Farben der Darstellung uebernehmen.
#>
function Get-DataGridStyle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Header', 'Row')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$Brushes
    )
    try {
        $ns = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        if ($Kind -eq 'Header') {
            $styleXaml = @"
<Style xmlns="$ns" TargetType="DataGridColumnHeader">
    <Setter Property="Background" Value="$($Brushes['HeaderBg'].Color)"/>
    <Setter Property="Foreground" Value="$($Brushes['AccentFg'].Color)"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="BorderBrush" Value="$($Brushes['LineBrush'].Color)"/>
    <Setter Property="BorderThickness" Value="0,0,1,1"/>
</Style>
"@
        } else {
            $styleXaml = @"
<Style xmlns="$ns" TargetType="DataGridRow">
    <Setter Property="Foreground" Value="$($Brushes['TextFg'].Color)"/>
    <Style.Triggers>
        <DataTrigger Binding="{Binding AlertValue}" Value="Unhealthy">
            <Setter Property="Background" Value="$($Brushes['UnhealthyRowBg'].Color)"/>
            <Setter Property="Foreground" Value="$($Brushes['UnhealthyRowFg'].Color)"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding AlertValue}" Value="Degraded">
            <Setter Property="Background" Value="$($Brushes['DegradedRowBg'].Color)"/>
            <Setter Property="Foreground" Value="$($Brushes['DegradedRowFg'].Color)"/>
        </DataTrigger>
    </Style.Triggers>
</Style>
"@
        }
        return [System.Windows.Markup.XamlReader]::Parse($styleXaml)
    } catch {
        Write-Log -Message ('Get-DataGridStyle ({0}): {1}' -f $Kind, $_.Exception.Message) -Level 'WARN'
        return $null
    }
}

<#
.SYNOPSIS
    Wendet die Farbpalette Light oder Dark auf die Oberflaeche an (Laufzeitwechsel).
.DESCRIPTION
    Der Wechsel erfolgt zweigleisig, weil WPF das Ersetzen von DynamicResource-
    Eintraegen nur fuer Style-Setter unterstuetzt:
      1. Steuerelemente mit direkt gebundenen Eigenschaften (Fenster, Container,
         DataGrid, Status-/Hinweistexte, Eingabefelder) erhalten lokale Pinselwerte.
      2. Die uebrigen Theme-Schluessel werden als Ressourcen ersetzt und versorgen
         damit alle Style-Setter (Panels, GroupBox, TextBox, ComboBox, Kopfzeilen
         und die Zeilen-Trigger des DataGrids).
#>
function Set-UiTheme {
    [CmdletBinding()]
    param([ValidateSet('Light', 'Dark')][string]$Theme)
    try {
        if (-not [string]::IsNullOrWhiteSpace($Theme)) { $Script:Config.Theme = $Theme }
        $palette = $Script:Themes[$Script:Config.Theme]
        $window  = $Script:Ui['Window']
        if (-not $palette -or -not $window) { return }

        $ui = $Script:Ui

        # Pinsel aus der aktiven Palette erzeugen (gefroren = schnelleres Rendering)
        $brushes = @{}
        foreach ($key in $palette.Keys) {
            $color = [System.Windows.Media.ColorConverter]::ConvertFromString([string]$palette[$key])
            $brush = New-Object System.Windows.Media.SolidColorBrush -ArgumentList $color
            [void]$brush.Freeze()
            $brushes[$key] = $brush
        }

        # --- 1) Direkt gebundene Eigenschaften: lokale Werte setzen -----------
        $window.Background = $brushes['WindowBg']
        $window.Foreground = $brushes['TextFg']

        foreach ($name in @('HeaderBorder', 'ToolbarBorder', 'ActionBorder', 'StatusBorder')) {
            if ($ui[$name]) { $ui[$name].Background = $brushes['PanelBg']; $ui[$name].BorderBrush = $brushes['LineBrush'] }
        }
        foreach ($name in @('GrpUnhealthy', 'GrpDetails')) {
            if ($ui[$name]) { $ui[$name].Foreground = $brushes['AccentFg']; $ui[$name].BorderBrush = $brushes['LineBrush'] }
        }
        foreach ($name in @('TxtServer', 'TxtDetails')) {
            if ($ui[$name]) {
                $ui[$name].Background  = $brushes['InputBg']
                $ui[$name].Foreground  = $brushes['TextFg']
                $ui[$name].BorderBrush = $brushes['LineBrush']
            }
        }
        if ($ui['TxtBusy'])     { $ui['TxtBusy'].Foreground = $brushes['WarnFg'] }
        if ($ui['TxtRightInfo']) { $ui['TxtRightInfo'].Foreground = $brushes['AccentFg'] }
        if ($ui['TxtStatus'])   { $ui['TxtStatus'].Foreground = $brushes['TextFg'] }

        foreach ($comboName in @('CmbLanguage', 'CmbTheme', 'CmbHours')) {
            $combo = $ui[$comboName]
            if ($combo) {
                $combo.Background  = $brushes['InputBg']
                $combo.Foreground  = $brushes['TextFg']
                $combo.BorderBrush = $brushes['LineBrush']
                foreach ($item in $combo.Items) {   # Popupliste (ComboBoxItem)
                    $item.Background = $brushes['InputBg']
                    $item.Foreground = $brushes['TextFg']
                }
            }
        }

        if ($ui['ChkAutoRefresh']) {
            $ui['ChkAutoRefresh'].Foreground  = $brushes['TextFg']
            $ui['ChkAutoRefresh'].Background  = $brushes['InputBg']
            $ui['ChkAutoRefresh'].BorderBrush = $brushes['LineBrush']
        }

        $grid = $ui['DgUnhealthy']
        if ($grid) {
            $grid.Background               = $brushes['GridBg']
            $grid.RowBackground            = $brushes['RowBg']
            $grid.AlternatingRowBackground = $brushes['RowAltBg']
            $grid.HorizontalGridLinesBrush = $brushes['LineBrush']
            $grid.Foreground               = $brushes['TextFg']

            # Kopfzeilen- und Zeilenstil (inkl. Trigger) neu aufbauen
            $headerStyle = Get-DataGridStyle -Kind 'Header' -Brushes $brushes
            if ($headerStyle) { $grid.ColumnHeaderStyle = $headerStyle }
            $rowStyle = Get-DataGridStyle -Kind 'Row' -Brushes $brushes
            if ($rowStyle) { $grid.RowStyle = $rowStyle }
        }

        # --- 2) Ressourcen ersetzen: versorgt alle Style-Setter ---------------
        foreach ($key in $palette.Keys) {
            try {
                $window.Resources[$key] = $brushes[$key]
            } catch {
                # Einzelne Keys koennen nicht ersetzt werden - bereits gesetzte
                # lokale Werte greifen weiterhin.
                Write-Log -Message ('Theme-Ressource {0}: {1}' -f $key, $_.Exception.Message) -Level 'DEBUG'
            }
        }

        # Umschalter synchron halten (loest keinen weiteren Wechsel aus)
        if ($ui['CmbTheme']) {
            $index = if ($Script:Config.Theme -eq 'Dark') { 1 } else { 0 }
            if ($ui['CmbTheme'].SelectedIndex -ne $index) { $ui['CmbTheme'].SelectedIndex = $index }
        }
        Write-Log -Message ('Darstellung gewechselt: {0}' -f $Script:Config.Theme) -Level 'DEBUG'
    } catch {
        Write-Log -Message ('Set-UiTheme: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}
#endregion

#region Asynchrone Ausfuehrung (Runspaces + DispatcherTimer)
<#
.SYNOPSIS
    Erstellt die benoetigten Runspaces (lokal und fuer Exchange-Abfragen).
#>
function Initialize-Runspaces {
    [CmdletBinding()]
    param()
    try {
        $Script:LocalRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $Script:LocalRunspace.ThreadOptions = 'ReuseThread'
        $Script:LocalRunspace.Open()

        $Script:ExchangeRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $Script:ExchangeRunspace.ThreadOptions = 'ReuseThread'
        $Script:ExchangeRunspace.Open()

        Write-Log -Message 'Runspaces initialisiert.'
    } catch {
        Write-Log -Message ('Initialize-Runspaces: {0}' -f $_.Exception.Message) -Level 'ERROR'
        throw
    }
}

<#
.SYNOPSIS
    Schliesst alle Runspaces (Aufruf beim Beenden).
#>
function Close-Runspaces {
    [CmdletBinding()]
    param()
    try {
        foreach ($rs in @($Script:ExchangeRunspace, $Script:LocalRunspace)) {
            if ($rs) {
                try { $rs.Close() } catch { }
                try { $rs.Dispose() } catch { }
            }
        }
        $Script:ExchangeRunspace = $null
        $Script:LocalRunspace = $null
    } catch {
        Write-Log -Message ('Close-Runspaces: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}

<#
.SYNOPSIS
    Bricht den aktuell laufenden Hintergrundtask ab.
#>
function Close-AsyncTasks {
    [CmdletBinding()]
    param()
    try {
        $ctx = $Script:Async
        if ($ctx) {
            try { $ctx.Timer.Stop() } catch { }
            try { $ctx.PS.Stop() } catch { }
            try { $ctx.PS.Dispose() } catch { }
        }
    } catch {
        Write-Log -Message ('Close-AsyncTasks: {0}' -f $_.Exception.Message) -Level 'WARN'
    } finally {
        $Script:Async = $null
        $Script:State.Busy = $false
    }
}

<#
.SYNOPSIS
    Fuehrt ein Skript asynchron in einem Runspace aus und ruft danach OnComplete auf.
.DESCRIPTION
    Die GUI bleibt reaktionsfaehig, weil das Ergebnis ueber einen DispatcherTimer
    abgeholt wird (statt blockierend auf EndInvoke zu warten).
#>
function Start-AsyncTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory)][scriptblock]$OnComplete,
        [string]$BusyTextKey = 'StatusLoading',
        [switch]$UseLocalRunspace
    )
    try {
        if ($Script:State.Busy) {
            Write-Log -Message 'Start-AsyncTask: Es laeuft bereits eine Operation - Abbruch.' -Level 'WARN'
            return
        }
        $runspace = if ($UseLocalRunspace) { $Script:LocalRunspace } else { $Script:ExchangeRunspace }
        if (-not $runspace) { throw 'Runspace nicht initialisiert.' }

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($Script)
        foreach ($key in $Parameters.Keys) { [void]$ps.AddParameter($key, $Parameters[$key]) }

        $handle = $ps.BeginInvoke()
        $timer  = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [System.TimeSpan]::FromMilliseconds(200)

        $Script:Async = @{ PS = $ps; Handle = $handle; Timer = $timer; OnComplete = $OnComplete }

        $timer.Add_Tick({
            try {
                $ctx = $Script:Async
                if (-not $ctx) { return }
                $state = $ctx.PS.InvocationStateInfo.State
                if ($state -eq 'Completed' -or $state -eq 'Failed' -or $state -eq 'Stopped') {
                    $ctx.Timer.Stop()
                    $Script:Async = $null

                    $output = @()
                    $errors = @()
                    try { $output = @($ctx.PS.EndInvoke($ctx.Handle)) } catch { $errors += $_.Exception }
                    if ($ctx.PS.Streams.Error.Count -gt 0) { $errors += @($ctx.PS.Streams.Error) }
                    try { $ctx.PS.Dispose() } catch { }

                    Set-Busy -Active $false
                    if ($ctx.OnComplete) { & $ctx.OnComplete $output $errors }
                }
            } catch {
                Write-Log -Message ('Async-Tick: {0}' -f $_.Exception.Message) -Level 'ERROR'
                Set-Busy -Active $false
            }
        })

        Set-Busy -Active $true -TextKey $BusyTextKey
        $timer.Start()
    } catch {
        Set-Busy -Active $false
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Startet/Stoppt den Auto-Refresh-Timer anhand der Checkbox.
#>
function Update-AutoRefreshTimer {
    [CmdletBinding()]
    param()
    try {
        if (-not $Script:AutoRefreshTimer) {
            $Script:AutoRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
            $Script:AutoRefreshTimer.Add_Tick({
                try {
                    if ($Script:State.Busy) { return }
                    Write-Log -Message 'Auto-Refresh: Starte neuen Health-Scan.' -Level 'DEBUG'
                    Start-HealthScan
                } catch {
                    Write-Log -Message ('Auto-Refresh-Tick: {0}' -f $_.Exception.Message) -Level 'ERROR'
                }
            })
        }

        $Script:AutoRefreshTimer.Interval = [System.TimeSpan]::FromMinutes([Math]::Max(1, $Script:Config.AutoRefreshMinutes))
        if ($Script:Ui['ChkAutoRefresh'].IsChecked) {
            $Script:AutoRefreshTimer.Start()
            Set-Status -Key 'StatusAutoRefresh' -Arguments @($Script:Config.AutoRefreshMinutes)
            Write-Log -Message ('Auto-Refresh aktiviert ({0} Min).' -f $Script:Config.AutoRefreshMinutes)
        } else {
            $Script:AutoRefreshTimer.Stop()
            Set-Status -Key 'StatusReady'
            Write-Log -Message 'Auto-Refresh deaktiviert.'
        }
    } catch {
        Write-Log -Message ('Update-AutoRefreshTimer: {0}' -f $_.Exception.Message) -Level 'ERROR'
    }
}
#endregion

#region Exchange-Verwaltung initialisieren
<#
.SYNOPSIS
    Laedt die Exchange-Verwaltungsshell im Hintergrund-Runspace und startet danach
    automatisch den ersten Health-Scan.
#>
function Start-ExchangeInitialization {
    [CmdletBinding()]
    param()
    try {
        # Snapshot/Module werden bewusst im Runspace geladen, damit die GUI nicht blockiert.
        $initScript = @'
param()
$result = @{ Loaded = $false; Provider = ''; Errors = @() }
try {
    if (Get-Command -Name Get-HealthReport -ErrorAction SilentlyContinue) {
        $result.Provider = 'already loaded'
    }

    # 1) Registrierte PowerShell-Snapins pruefen und laden (SE zuerst)
    if (-not $result.Provider) {
        $registered = @()
        try { $registered = @(Get-PSSnapin -Registered -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) } catch { }
        foreach ($snapin in @('Microsoft.Exchange.Management.PowerShell.SE','Microsoft.Exchange.Management.PowerShell.E2010')) {
            if ($registered -contains $snapin) {
                try {
                    Add-PSSnapin -Name $snapin -ErrorAction Stop
                    $result.Provider = $snapin
                    break
                } catch {
                    $result.Errors += ('{0}: {1}' -f $snapin, $_.Exception.Message)
                }
            } else {
                $result.Errors += ('{0}: Snapin nicht registriert' -f $snapin)
            }
        }
    }

    # 2) Fallback: Standard-Initialisierung der Exchange-Verwaltungsshell
    if (-not $result.Provider -and $env:ExchangeInstallPath) {
        $remoteExchange = Join-Path $env:ExchangeInstallPath 'bin\RemoteExchange.ps1'
        if (Test-Path -LiteralPath $remoteExchange) {
            try {
                . $remoteExchange
                if (Get-Command -Name Get-HealthReport -ErrorAction SilentlyContinue) { $result.Provider = 'RemoteExchange.ps1' }
            } catch {
                $result.Errors += ('RemoteExchange.ps1: {0}' -f $_.Exception.Message)
            }
        }
    }

    $result.Loaded = [bool](Get-Command -Name Get-HealthReport -ErrorAction SilentlyContinue)
} catch {
    $result.Errors += $_.Exception.Message
}
[pscustomobject]$result
'@

        $onDone = {
            param($out, $err)
            try {
                if (@($err).Count -gt 0) { Write-AsyncError -Errors $err }
                $result = @($out)[0]
                if ($result -and $result.Loaded) {
                    $Script:State.ExchangeLoaded = $true
                    Set-Status -Key 'StatusExchangeOk' -Arguments @($result.Provider)
                    Write-Log -Message ('Exchange-Verwaltung geladen via {0}.' -f $result.Provider)
                    Start-HealthScan
                } else {
                    $Script:State.ExchangeLoaded = $false
                    Set-Status -Key 'StatusExchangeLocal'
                    foreach ($e in @($result.Errors)) { Write-Log -Message ('Exchange-Init: {0}' -f $e) -Level 'WARN' }
                    Show-Error -Message (Get-Text -Key 'ErrNoExchange')
                }
            } catch {
                Write-Log -Message ('Exchange-Init-OnComplete: {0}' -f $_.Exception.Message) -Level 'ERROR'
            }
        }

        Start-AsyncTask -Script $initScript -OnComplete $onDone -BusyTextKey 'StatusLoadingExchange'
    } catch {
        Write-Log -Message ('Start-ExchangeInitialization: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Einheitliche Behandlung von Fehlern aus Hintergrund-Runspaces.
#>
function Write-AsyncError {
    [CmdletBinding()]
    param([object[]]$Errors)
    try {
        $messages = @()
        foreach ($item in @($Errors)) {
            if ($null -eq $item) { continue }
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $messages += $item.Exception.Message
            } else {
                $messages += [string]$item
            }
        }
        foreach ($message in $messages) {
            Write-Log -Message ('Hintergrundfehler: {0}' -f $message) -Level 'ERROR'
        }
        if ($messages.Count -gt 0) {
            Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($messages[0]))
        }
    } catch {
        Write-Log -Message ('Write-AsyncError: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}
#endregion

#region Health-Scan
<#
.SYNOPSIS
    Fuehrt Get-HealthReport gegen den Zielserver aus und zeigt nur ungesunde Checks.
#>
function Start-HealthScan {
    [CmdletBinding()]
    param()
    try {
        $server = Get-TargetServer
        if ([string]::IsNullOrWhiteSpace($server)) {
            Show-Error -Message (Get-Text -Key 'ErrNoServer') -Level 'WARN'
            return
        }
        if (-not $Script:State.ExchangeLoaded) {
            Show-Error -Message (Get-Text -Key 'ErrNoExchange') -Level 'WARN'
            return
        }

        $scanScript = @'
param([string]$Server)
$data = @(Get-HealthReport -Identity $Server -ErrorAction Stop)
foreach ($h in $data) {
    $monitor = ''
    foreach ($prop in @('Name','MonitorName')) {
        if ($h.PSObject.Properties[$prop] -and $h.$prop) { $monitor = [string]$h.$prop; break }
    }
    $transition = ''
    if ($h.PSObject.Properties['LastTransitionTime'] -and $h.LastTransitionTime) {
        $transition = ([datetime]$h.LastTransitionTime).ToString('yyyy-MM-dd HH:mm')
    }
    [pscustomobject]@{
        Server             = [string]$h.Server
        HealthSet          = [string]$h.HealthSet
        Monitor            = $monitor
        AlertValue         = [string]$h.AlertValue
        LastTransitionTime = $transition
        TargetResource     = [string]$h.TargetResource
        RepeatCount        = $h.RepeatCount
        RedAlertCount      = $h.RedAlertCount
    }
}
'@

        $onDone = {
            param($out, $err)
            try {
                if (@($err).Count -gt 0) { Write-AsyncError -Errors $err }
                $all = @($out)
                $Script:State.HealthData    = $all
                $Script:State.LastScanTime  = Get-Date
                $Script:State.Unhealthy     = @($all | Where-Object { (Get-AlertText -Value $_.AlertValue) -ne 'Healthy' })
                Update-HealthGrid
                Set-Status -Key 'StatusScanDone' -Arguments @($Script:State.Unhealthy.Count, $all.Count)
                if ($Script:Ui['TxtRightInfo']) {
                    $Script:Ui['TxtRightInfo'].Text = '{0}: {1} | {2}' -f (Get-Text -Key 'HtmlServer'), (Get-TargetServer), (Get-Date -Format 'dd.MM.yyyy HH:mm')
                }
                Write-Log -Message ('Health-Scan abgeschlossen: {0} ungesunde von {1} Checks ({2}).' -f $Script:State.Unhealthy.Count, $all.Count, (Get-TargetServer))
            } catch {
                Write-Log -Message ('Health-Scan-OnComplete: {0}' -f $_.Exception.Message) -Level 'ERROR'
                Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
            }
        }

        Start-AsyncTask -Script $scanScript -Parameters @{ Server = $server } -OnComplete $onDone -BusyTextKey 'StatusScanning'
    } catch {
        Write-Log -Message ('Start-HealthScan: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Uebertraegt die gefilterten Checks in das DataGrid.
#>
function Update-HealthGrid {
    [CmdletBinding()]
    param()
    try {
        $grid = $Script:Ui['DgUnhealthy']
        if (-not $grid) { return }
        $grid.ItemsSource = $null
        $grid.ItemsSource = $Script:State.Unhealthy
        if (@($Script:State.Unhealthy).Count -gt 0) {
            # Erste Zeile vorauswaehlen und die Auswahl direkt hinterlegen
            # (das SelectionChanged-Event feuert nicht in jedem Fall synchron)
            $grid.SelectedIndex = 0
            $Script:State.Selected = $grid.SelectedItem
        } else {
            $Script:State.Selected = $null
        }
    } catch {
        Write-Log -Message ('Update-HealthGrid: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}
#endregion

#region Deep-Dive Analyse (HealthSet -> Monitore -> Eventlogs)
<#
.SYNOPSIS
    Analysiert das markierte HealthSet: ungesunde Monitore, Zielressourcen und
    die passenden ActiveMonitoring-Eventlogs.
#>
function Invoke-DeepDive {
    [CmdletBinding()]
    param()
    try {
        $row = $Script:State.Selected
        if (-not $row) {
            Show-Error -Message (Get-Text -Key 'MsgNoSelection') -Level 'WARN'
            return
        }
        if (-not $Script:State.ExchangeLoaded) {
            Show-Error -Message (Get-Text -Key 'ErrNoExchange') -Level 'WARN'
            return
        }

        $server    = Get-TargetServer
        $healthSet = [string]$row.HealthSet

        $analysisScript = @'
param([string]$Server, [string]$HealthSet, [int]$LogHours, [int]$MaxEvents, [string[]]$LogNames)
$result = @{ HealthSet = $HealthSet; Server = $Server; Monitors = @(); Events = @(); Errors = @(); Logs = $LogNames; Probes = @(); ProbeRuns = @() }

# Lokal ohne -ComputerName arbeiten (schneller und robuster als der Loopback-Weg)
$localName = $env:COMPUTERNAME
$isRemote  = $Server -and ($Server -ne $localName) -and ($Server -ne 'localhost') -and ($Server -ne '127.0.0.1') -and ($Server -ne '.')

function Get-PropValue($obj, [string[]]$names) {
    foreach ($n in $names) {
        try {
            if ($obj.PSObject.Properties[$n] -and $null -ne $obj.$n -and ([string]$obj.$n) -ne '') { return [string]$obj.$n }
        } catch { }
    }
    return ''
}
function Get-TimeValue($obj, [string[]]$names) {
    foreach ($n in $names) {
        try {
            if ($obj.PSObject.Properties[$n] -and $obj.$n) {
                $dt = [datetime]$obj.$n
                if ($dt.Year -gt 1900) { return $dt.ToString('yyyy-MM-dd HH:mm') }
            }
        } catch { }
    }
    return ''
}
function Clean-EventMessage([string]$text) {
    # Eskalationsmeldungen aus ManagedAvailability/Monitoring enthalten HTML-Markup
    # (<b>, <br/>, <table>...) und eine angehaengte Monitor-Uebersichtstabelle
    # (ggf. veraltet und irrefuehrend). Beides wird entfernt, uebrig bleibt der
    # eigentliche Fehlertext.
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    try {
        $text = $text -replace 'REPLACE_PERCENT_SIGN', '%'
        $text = $text -replace '(?i)</?(br|hr|p|div|table|tbody|thead|tr|td|th|b|i|u|span|font|a)(\s[^>]*)?/?>', ' '
        foreach ($marker in @('Status aller Monitore', 'Status of all monitors')) {
            $idx = $text.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
            if ($idx -gt 0) { $text = $text.Substring(0, $idx) }
        }
        $text = $text.TrimEnd('-', ' ', "`t")
        $text = $text -replace '\s{2,}', ' '
        return $text.Trim()
    } catch { return $text }
}

# 1) Ungesunde Monitore des HealthSets ermitteln.
# Hinweis: Get-ServerHealth kennt KEIN RepeatCount/RedAlertCount (das sind
# Get-HealthReport-Felder). Die echten Fehlerdetails stehen in Error, Exception,
# Description, LastExecutionResult, FirstAlertObservedTime u. a. Zusaetzlich
# werden alle sonstigen nicht-leeren Properties als Extended-String
# mitgeschleppt, damit bei SE-Abweichungen nichts verloren geht.
$knownProps = @('Name','AlertValue','TargetResource','HealthSetName','HealthGroupName','LastTransitionTime','FirstFailedTime','FirstAlertObservedTime','LastExecutionTime','LastExecutionResult','Description','HealthSetDescription','Error','Exception','IsStale','RepeatCount','RedAlertCount')
try {
    $monitors = @(Get-ServerHealth -Identity $Server -HealthSet $HealthSet -ErrorAction Stop)
    $unhealthy = @($monitors | Where-Object { [string]$_.AlertValue -ne 'Healthy' })
    $result.Monitors = @($unhealthy | ForEach-Object {
        $extra = @()
        # Interne IDs sind Rauschen (ResultId, WorkItemId, ...), keine Diagnoseinfo
        $noiseProps = @('Identity', 'ResultId', 'WorkItemId', 'IsValid', 'ObjectState', 'ServicePriority', 'DefinitionCreatedTime')
        foreach ($p in $_.PSObject.Properties) {
            try {
                if ($knownProps -contains $p.Name) { continue }
                if ($noiseProps -contains $p.Name) { continue }
                if ($null -eq $p.Value) { continue }
                $v = ([string]$p.Value).Trim()
                if ($v -eq '' -or $v -eq '1/1/0001 12:00:00 AM' -or $v -eq '01.01.0001 00:00:00') { continue }
                if ($v.Length -gt 300) { $v = $v.Substring(0, 300) + ' ...' }
                $extra += ('{0}={1}' -f $p.Name, ($v -replace "`r?`n", ' '))
            } catch { }
        }
        [pscustomobject]@{
            Name                 = Get-PropValue $_ @('Name')
            AlertValue           = Get-PropValue $_ @('AlertValue')
            TargetResource       = Get-PropValue $_ @('TargetResource')
            HealthSetName        = Get-PropValue $_ @('HealthSetName')
            HealthGroupName      = Get-PropValue $_ @('HealthGroupName')
            LastTransitionTime   = Get-TimeValue $_ @('LastTransitionTime')
            FirstFailedTime      = Get-TimeValue $_ @('FirstFailedTime', 'FirstAlertObservedTime')
            LastExecutionTime    = Get-TimeValue $_ @('LastExecutionTime')
            LastExecutionResult  = Get-PropValue $_ @('LastExecutionResult')
            Description          = Get-PropValue $_ @('Description', 'HealthSetDescription')
            Error                = Get-PropValue $_ @('Error')
            Exception            = Get-PropValue $_ @('Exception')
            IsStale              = Get-PropValue $_ @('IsStale')
            RepeatCount          = Get-PropValue $_ @('RepeatCount', 'RedAlertCount')
            Extended             = ($extra -join ' | ')
        }
    })
} catch {
    $result.Errors += ('Get-ServerHealth: {0}' -f $_.Exception.Message)
}

# 1b) Proben des HealthSets auflisten (fuer konkrete Invoke-Befehle und Live-Fallback).
try {
    $items = @(Get-MonitoringItemIdentity -Identity $HealthSet -Server $Server -ErrorAction Stop)
    $result.Probes = @($items | Where-Object { [string]$_.ItemType -eq 'Probe' } | ForEach-Object {
        [pscustomobject]@{
            Name = Get-PropValue $_ @('Name')
            Identity = Get-PropValue $_ @('Identity')
            TargetResource = Get-PropValue $_ @('TargetResource')
        }
    })
} catch {
    $result.Errors += ('Get-MonitoringItemIdentity: {0}' -f $_.Exception.Message)
}

# 1c) Live-Probe als Fallback: liefert den echten Fehler auch bei deaktivierten Logs.
# Nur max. 2 passende Probes (DeepTest zuerst), damit kein Massenlauf entsteht.
try {
    foreach ($mon in @($result.Monitors)) {
        $monitorBase = ([string]$mon.Name) -replace '\.?(Monitor|Responder)$', ''
        $candidates = @($result.Probes | Where-Object { ([string]$_.Name) -like ('*{0}*' -f $monitorBase) })
        if (@($candidates).Count -eq 0) {
            $candidates = @($result.Probes | Where-Object { ([string]$_.Name) -like '*DeepTest*' } | Select-Object -First 1)
        }
        $candidates = @($candidates | Select-Object -First 2)
        foreach ($probe in $candidates) {
            $identity = [string]$probe.Identity
            if ([string]::IsNullOrWhiteSpace($identity)) {
                if ([string]::IsNullOrWhiteSpace([string]$probe.Name)) { continue }
                $identity = '{0}\{1}' -f $HealthSet, [string]$probe.Name
            }
            if (@($result.ProbeRuns | Where-Object { $_.Identity -eq $identity }).Count -gt 0) { continue }
            try {
                $pr = Invoke-MonitoringProbe -Identity $identity -Server $Server -ErrorAction Stop
                $value = Get-PropValue $pr @('ProbeResult', 'Result')
                $errText = Get-PropValue $pr @('Error', 'Exception', 'FailureDetail')
                if ($value.Length -gt 800) { $value = $value.Substring(0, 800) + ' ...' }
                if ($errText.Length -gt 1500) { $errText = $errText.Substring(0, 1500) + ' ...' }
                $result.ProbeRuns += @([pscustomobject]@{ Identity = $identity; Status = 'OK'; Result = $value; Error = ($errText -replace "`r?`n", ' ') })
            } catch {
                $msg = [string]$_.Exception.Message
                # Nicht manuell startbare Probes (z. B. DatabaseSpaceProbe) still
                # uebergehen - kein verwirrender [ERROR]-Eintrag in der Anzeige
                if ($msg -match "(?i)(can't be used|cannot be run|not be run|Could not find assembly)") { continue }
                $result.ProbeRuns += @([pscustomobject]@{ Identity = $identity; Status = 'ERROR'; Result = ''; Error = ($msg -replace "`r?`n", ' ') })
            }
        }
    }
} catch {
    $result.Errors += ('Invoke-MonitoringProbe (Fallback): {0}' -f $_.Exception.Message)
}

# 2) Passende Eventlogs der Managed Availability auslesen.
# ProbeResult/MonitorResult/ResponderResult sind auf Produktivservern oft
# deaktiviert (Performance). Microsoft-Exchange-ManagedAvailability/Monitoring
# enthaelt die Eskalationsmeldung inkl. letztem Probe-Fehler und ist daher
# die wichtigste Quelle. Deaktivierte Logs werden trotzdem leseversucht
# (alte Events koennen noch vorhanden sein) und nur als Hinweis vermerkt.
$since = (Get-Date).AddHours(-1 * [Math]::Max(1, $LogHours))
$events = New-Object System.Collections.ArrayList
$logsToRead = @($LogNames) + @('Application')
foreach ($logName in ($logsToRead | Select-Object -Unique)) {
    $isAppLog = ($logName -eq 'Application')
    # Log vorab pruefen (nur Hinweis, kein Skip - alte Events bleiben lesbar)
    try {
        $logInfo = if ($isRemote) { Get-WinEvent -ListLog $logName -ComputerName $Server -ErrorAction Stop } else { Get-WinEvent -ListLog $logName -ErrorAction Stop }
        if ($logInfo -and -not $logInfo.LogIsEnabled) {
            $result.Errors += ('{0}: Log deaktiviert (LogIsEnabled=False)' -f $logName)
        }
    } catch {
        # Log nicht vorhanden oder nicht lesbar - wird beim Auslesen erneut gemeldet
    }

    $evts = @()
    try {
        if ($isAppLog) {
            # Application-Log: nur Fehler/Warnungen im Zeitfenster (sonst zu viel Rauschen)
            $filter = @{ LogName = $logName; StartTime = $since; Level = @(1, 2, 3) }
        } else {
            $filter = @{ LogName = $logName; StartTime = $since }
        }
        if ($isRemote) { $evts = @(Get-WinEvent -ComputerName $Server -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop) }
        else           { $evts = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop) }
    } catch {
        # Fallback: ohne Zeitfilter lesen und anschliessend auf das Zeitfenster begrenzen
        try {
            if ($isRemote) { $evts = @(Get-WinEvent -ComputerName $Server -LogName $logName -MaxEvents $MaxEvents -ErrorAction Stop) }
            else           { $evts = @(Get-WinEvent -LogName $logName -MaxEvents $MaxEvents -ErrorAction Stop) }
            $evts = @($evts | Where-Object { -not $_.TimeCreated -or ([datetime]$_.TimeCreated) -ge $since })
        } catch {
            $result.Errors += ('{0}: {1}' -f $logName, $_.Exception.Message)
            $evts = @()
        }
    }
    foreach ($e in $evts) {
        $message = [string]$e.Message
        $message = $message -replace "`r?`n", ' '
        $message = Clean-EventMessage $message
        if ($message.Length -gt 1500) { $message = $message.Substring(0, 1500) + ' ...' }
        # Echter Fehlertext steckt bei ActiveMonitoring-Events im XML (Error,
        # Exception, ResultName) - Message allein ist oft nur generisch
        # ("Probe result (Name=...)"). Daher XML-Details mit auslesen.
        $detail = ''
        try {
            $xml = [xml]$e.ToXml()
            $nodes = @($xml.SelectNodes('//*[local-name()="Error" or local-name()="Exception" or local-name()="ResultName" or local-name()="MonitorName" or local-name()="ProbeName" or local-name()="ResultType"]'))
            $parts = @()
            foreach ($n in $nodes) {
                $t = ([string]$n.InnerText).Trim() -replace "`r?`n", ' '
                if ($t -and $t.Length -gt 0) {
                    if ($t.Length -gt 800) { $t = $t.Substring(0, 800) + ' ...' }
                    $parts += ('{0}={1}' -f $n.LocalName, $t)
                }
            }
            $detail = ($parts | Select-Object -Unique) -join ' | '
            if ($detail.Length -gt 1500) { $detail = $detail.Substring(0, 1500) + ' ...' }
        } catch { $detail = '' }
        $timeCreated = ''
        if ($e.PSObject.Properties['TimeCreated'] -and $e.TimeCreated) {
            $timeCreated = ([datetime]$e.TimeCreated).ToString('yyyy-MM-dd HH:mm:ss')
        }
        [void]$events.Add([pscustomobject]@{
            TimeCreated = $timeCreated
            LogName     = $logName
            Level       = [string]$e.LevelDisplayName
            Id          = $e.Id
            Message     = $message
            Detail      = $detail
        })
    }
}
$result.Events = @($events | Sort-Object TimeCreated -Descending)
[pscustomobject]$result
'@

        $onDone = {
            param($out, $err)
            try {
                if (@($err).Count -gt 0) { Write-AsyncError -Errors $err }
                $result = @($out)[0]
                if (-not $result) {
                    $result = [pscustomobject]@{ HealthSet = ''; Server = ''; Monitors = @(); Events = @(); Errors = @() }
                }
                $Script:State.AnalyseResult = $result
                Show-AnalyseResult -Result $result
                Write-Log -Message ('Deep-Dive abgeschlossen: {0}, {1} Monitor(e), {2} Event(s).' -f $result.HealthSet, @($result.Monitors).Count, @($result.Events).Count)
            } catch {
                Write-Log -Message ('Deep-Dive-OnComplete: {0}' -f $_.Exception.Message) -Level 'ERROR'
                Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
            }
        }

        Start-AsyncTask -Script $analysisScript -Parameters @{
            Server    = $server
            HealthSet = $healthSet
            LogHours  = $Script:Config.EventLogHours
            MaxEvents = $Script:Config.MaxEventsPerLog
            LogNames  = $Script:Config.MonitoringLogs
        } -OnComplete $onDone -BusyTextKey 'StatusAnalyzing'
    } catch {
        Write-Log -Message ('Invoke-DeepDive: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Formatiert das Analyseergebnis fuer die Detail-Textbox (sprachabhaengig).
#>
function Show-AnalyseResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)
    try {
        $sb = New-Object System.Text.StringBuilder
        $line = ('=' * 96) -join ''
        $thin = ('-' * 96) -join ''

        [void]$sb.AppendLine($line)
        [void]$sb.AppendLine((Get-TextF -Key 'DetailsTitle' -Arguments @($Result.HealthSet)))
        [void]$sb.AppendLine(('{0}: {1}' -f (Get-Text -Key 'HtmlServer'), (Get-TargetServer)))
        [void]$sb.AppendLine(('{0}: {1}' -f (Get-Text -Key 'HtmlCreated'), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
        [void]$sb.AppendLine($line)

        $monitors = @($Result.Monitors)
        if ($monitors.Count -eq 0) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((Get-Text -Key 'DetailsNoEvents'))
        }
        $errTotal = 0

        foreach ($monitor in $monitors) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine($thin)
            [void]$sb.AppendLine((Get-TextF -Key 'DetailsMonitor' -Arguments @($monitor.Name)))
            [void]$sb.AppendLine((Get-TextF -Key 'DetailsStatus' -Arguments @($monitor.AlertValue)))
            [void]$sb.AppendLine((Get-TextF -Key 'DetailsTarget' -Arguments @($monitor.TargetResource)))
            [void]$sb.AppendLine((Get-TextF -Key 'DetailsLastChange' -Arguments @($monitor.LastTransitionTime)))
            if ($monitor.FirstFailedTime) {
                [void]$sb.AppendLine((Get-TextF -Key 'DetailsFirstFailed' -Arguments @($monitor.FirstFailedTime)))
            }
            if ($monitor.LastExecutionTime -or $monitor.LastExecutionResult) {
                [void]$sb.AppendLine((Get-TextF -Key 'DetailsLastExec' -Arguments @($monitor.LastExecutionTime, $monitor.LastExecutionResult)))
            }
            # Get-ServerHealth kennt kein RepeatCount (Get-HealthReport-Feld).
            # Fallback: Wert aus der Scan-Zeile uebernehmen, sonst als n/a kennzeichnen.
            $counter = [string]$monitor.RepeatCount
            if ([string]::IsNullOrWhiteSpace($counter) -and $Script:State.Selected -and $Script:State.Selected.PSObject.Properties['RepeatCount'] -and $null -ne $Script:State.Selected.RepeatCount) {
                $counter = [string]$Script:State.Selected.RepeatCount
            }
            if ([string]::IsNullOrWhiteSpace($counter)) { $counter = 'n/a' }
            [void]$sb.AppendLine((Get-TextF -Key 'DetailsCounter' -Arguments @($counter)))
            if ($monitor.Description) { [void]$sb.AppendLine((Get-TextF -Key 'DetailsDescription' -Arguments @($monitor.Description))) }
            if ($monitor.Error)       { [void]$sb.AppendLine((Get-TextF -Key 'DetailsError' -Arguments @($monitor.Error))) }
            if ($monitor.Exception)   { [void]$sb.AppendLine((Get-TextF -Key 'DetailsException' -Arguments @($monitor.Exception))) }
            if ([string]$monitor.IsStale -match '^(True|1)$') {
                [void]$sb.AppendLine((Get-Text -Key 'DetailsStale'))
            }
            if ($monitor.Extended) {
                $ext = [string]$monitor.Extended
                if ($ext.Length -gt 1200) { $ext = $ext.Substring(0, 1200) + ' ...' }
                [void]$sb.AppendLine((Get-TextF -Key 'DetailsExtended' -Arguments @($ext)))
            }
            # Konkrete Proben des HealthSets (statt <ProbeName>-Platzhalter)
            $probes = @($Result.Probes)
            if ($probes.Count -gt 0) {
                $probeNames = @($probes | ForEach-Object { [string]$_.Name } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 8)
                if ($probeNames.Count -gt 0) {
                    [void]$sb.AppendLine((Get-TextF -Key 'DetailsProbes' -Arguments @(($probeNames -join ', '))))
                }
            }
            # Live-Probe-Ergebnis (Fallback bei deaktivierten Logs)
            $runs = @($Result.ProbeRuns)
            if ($runs.Count -gt 0) {
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine((Get-Text -Key 'DetailsLiveProbe'))
                foreach ($run in $runs) {
                    # Status aus dem Probe-Inhalt ableiten: [OK] heisst nur, dass das
                    # Cmdlet lief - ein Fehlertext bedeutet trotzdem einen Fehlschlag.
                    $runState = [string]$run.Status
                    if (-not [string]::IsNullOrWhiteSpace([string]$run.Error)) { $runState = Get-Text -Key 'DetailsProbeFailed' }
                    [void]$sb.AppendLine(('  [{0}] {1}' -f $runState, $run.Identity))
                    if ($run.Result) { [void]$sb.AppendLine(('    Result: {0}' -f $run.Result)) }
                    if ($run.Error)  { [void]$sb.AppendLine((Get-TextF -Key 'DetailsRunError' -Arguments @($run.Error))) }
                    if (-not $run.Result -and -not $run.Error -and [string]$run.Status -eq 'OK') {
                        [void]$sb.AppendLine(('    {0}' -f (Get-Text -Key 'DetailsLiveOk')))
                    }
                }
            }
            [void]$sb.AppendLine('')

            # Suchbegriffe, nach Relevanz getrennt: Monitor-/Probe-Namen sind stark,
            # HealthSet/Zielressource allein sind schwach (z. B. matcht der AppPool-Name
            # fast jede Probe). Fehler-Eintraege (Level Fehler/Warnung oder
            # ResultType 1/4) werden zuerst gezeigt, reine Infos ausgeblendet.
            $strongTokens = @()
            if ($monitor.Name) {
                $strongTokens += [string]$monitor.Name
                $strongTokens += (([string]$monitor.Name) -replace '\.?(Monitor|Responder|Probe)$', '')
            }
            foreach ($pb in @($Result.Probes)) {
                if ($pb.Name) { $strongTokens += [string]$pb.Name }
            }
            $strongTokens = @($strongTokens | Where-Object { $_ } | Select-Object -Unique)
            $weakTokens = @()
            if ($Result.HealthSet)         { $weakTokens += [string]$Result.HealthSet }
            if ($monitor.TargetResource)   { $weakTokens += [string]$monitor.TargetResource }
            if ($monitor.HealthSetName)    { $weakTokens += [string]$monitor.HealthSetName }
            $weakTokens = @($weakTokens | Where-Object { $_ } | Select-Object -Unique | Where-Object { $strongTokens -notcontains $_ })

            $scored = New-Object System.Collections.ArrayList
            foreach ($evt in @($Result.Events)) {
                $text = ([string]$evt.Message + ' ' + [string]$evt.Detail)
                $strong = $false
                foreach ($token in $strongTokens) {
                    if ($text -like ('*{0}*' -f $token)) { $strong = $true; break }
                }
                if (-not $strong) {
                    $weak = $false
                    foreach ($token in $weakTokens) {
                        if ($text -like ('*{0}*' -f $token)) { $weak = $true; break }
                    }
                    if (-not $weak) { continue }
                }
                $isError = $false
                try {
                    if ([string]$evt.Level -match '(?i)(Fehler|Error|Warnung|Warning)') { $isError = $true }
                    elseif ([string]$evt.Detail -match 'ResultType=[14]([^0-9]|$)') { $isError = $true }
                } catch { }
                [void]$scored.Add([pscustomobject]@{ Event = $evt; Strong = $strong; IsError = $isError })
            }
            # Fehler immer aus ALLEN Treffern (stark+schwach): Ein starker Info-Treffer
            # darf einen schwachen Fehler-Treffer nicht verdraengen (z. B. MailboxSpace:
            # DatabaseSpaceProbe-Erfolge vs. HealthSet-weite Low-Space-Eskalation).
            # Schwache Fehler sind HealthSet-weite Aussagen und werden als solche
            # gekennzeichnet, nicht als Monitor-Fehler.
            $errStrong = @($scored | Where-Object { $_.Strong -and $_.IsError })
            $errWeak   = @($scored | Where-Object { -not $_.Strong -and $_.IsError })
            $infoAll   = @($scored | Where-Object { -not $_.IsError })
            $showErrorsOnly = ((@($errStrong).Count + @($errWeak).Count) -gt 0)
            $weakOnly = ((@($errStrong).Count -eq 0) -and (@($errWeak).Count -gt 0))
            if ($showErrorsOnly -and -not $weakOnly) {
                $errHits = $errStrong
            } elseif ($showErrorsOnly) {
                $errHits = $errWeak
            } else {
                $errHits = @()
            }
            $matching = @($errHits | ForEach-Object { $_.Event })
            # Ohne Fehler: nur zielbezogene Infos (enthalten die Zielressource) - ein
            # fremder Probe-Erfolg (z. B. DB03 unter DB01) wird nicht mehr angezeigt.
            $targetOnly = $false
            if (-not $showErrorsOnly -and $monitor.TargetResource) {
                $targetInfos = @($infoAll | Where-Object {
                    (([string]$_.Event.Message + ' ' + [string]$_.Event.Detail) -like ('*{0}*' -f $monitor.TargetResource))
                })
                if (@($targetInfos).Count -gt 0) { $targetOnly = $true; $matching = @($targetInfos | ForEach-Object { $_.Event }) }
            }
            # Identische Eintraege (z. B. InvokeNow-Wiederholungen) zusammenfassen:
            # neuester wird gezeigt, Rest nur gezaehlt.
            $shown = @()
            $seen = @{}
            foreach ($evt in $matching) {
                $dedupeKey = ([string]$evt.Message + '||' + [string]$evt.Detail)
                if ($seen.ContainsKey($dedupeKey)) { $seen[$dedupeKey].Count++ }
                else { $seen[$dedupeKey] = [pscustomobject]@{ Event = $evt; Count = 1 }; $shown += $seen[$dedupeKey] }
            }
            # Ausgeblendete Infos = alle Infos minus angezeigte (Fehlerzweige zeigen
            # keine Infos, der Zielzweig max. 3).
            $hiddenInfos = @($infoAll).Count
            if ($targetOnly) { $hiddenInfos = [Math]::Max(0, $hiddenInfos - @($shown | Select-Object -First 3).Count) }
            if ($matching.Count -eq 0) {
                $eventsRead = @($Result.Events).Count
                if ($eventsRead -eq 0) {
                    [void]$sb.AppendLine((Get-TextF -Key 'DetailsNoEventsRead' -Arguments @($Script:Config.EventLogHours)))
                } else {
                    [void]$sb.AppendLine((Get-Text -Key 'DetailsNoEvents'))
                }
                # Fallback: neueste Eintraege aus ManagedAvailability/Application zeigen,
                # damit nie wieder nur eine leere Detailseite erscheint.
                $fallback = @($Result.Events | Where-Object { ([string]$_.LogName -like '*ManagedAvailability*') -or ([string]$_.LogName -eq 'Application') } | Select-Object -First 3)
                if ($fallback.Count -gt 0) {
                    [void]$sb.AppendLine('')
                    [void]$sb.AppendLine((Get-TextF -Key 'DetailsFallbackEvents' -Arguments @('ManagedAvailability/Application', $fallback.Count)))
                    foreach ($logEntry in $fallback) {
                        [void]$sb.AppendLine(('  [{0}] {1} ({2})' -f $logEntry.TimeCreated, $logEntry.LogName, $logEntry.Level))
                        [void]$sb.AppendLine(('    {0}' -f $logEntry.Message))
                        if ($logEntry.Detail) { [void]$sb.AppendLine(('    Detail: {0}' -f $logEntry.Detail)) }
                    }
                }
                [void]$sb.AppendLine('')
                # Konkreter Probe-Befehl (erste passende Probe) statt Platzhalter
                $concreteProbe = ''
                try {
                    $monitorBase = ([string]$monitor.Name) -replace '\.?(Monitor|Responder)$', ''
                    $best = @($Result.Probes | Where-Object { ([string]$_.Name) -like ('*{0}*' -f $monitorBase) } | Select-Object -First 1)
                    if ($best.Count -gt 0 -and $best[0].Identity) { $concreteProbe = [string]$best[0].Identity }
                } catch { }
                if ($concreteProbe) {
                    [void]$sb.AppendLine((Get-TextF -Key 'DetailsProbeHintConcrete' -Arguments @($concreteProbe, (Get-TargetServer))))
                } else {
                    [void]$sb.AppendLine((Get-TextF -Key 'DetailsProbeHint' -Arguments @($Result.HealthSet, (Get-TargetServer))))
                }
            } else {
                if ($showErrorsOnly) {
                    # Nur Fehler zeigen, reine Infos (z. B. erfolgreiche Probes,
                    # RecoveryAction-Infos) ausblenden und nur zaehlen.
                    if ($weakOnly) {
                        [void]$sb.AppendLine((Get-TextF -Key 'DetailsErrorEventsWeak' -Arguments @($errHits.Count)))
                    } else {
                        [void]$sb.AppendLine((Get-TextF -Key 'DetailsErrorEvents' -Arguments @($errHits.Count)))
                    }
                    $errTotal += @($errHits).Count
                    foreach ($row in @($shown | Select-Object -First 5)) {
                        $logEntry = $row.Event
                        [void]$sb.AppendLine(('  [{0}] {1} ({2})' -f $logEntry.TimeCreated, $logEntry.LogName, $logEntry.Level))
                        $dupeSuffix = if ($row.Count -gt 1) { Get-TextF -Key 'DetailsDupes' -Arguments @($row.Count) } else { '' }
                        [void]$sb.AppendLine(('    {0}{1}' -f $logEntry.Message, $dupeSuffix))
                        if ($logEntry.Detail) { [void]$sb.AppendLine(('    Detail: {0}' -f $logEntry.Detail)) }
                    }
                    if ($hiddenInfos -gt 0) {
                        [void]$sb.AppendLine((Get-TextF -Key 'DetailsHiddenInfo' -Arguments @($hiddenInfos)))
                    }
                } else {
                    # Keine Fehler im Fenster: nur zielbezogene Infos im vollen Format
                    # (mit Quelle/Level). Fremde Erfolge erscheinen hier nicht mehr.
                    [void]$sb.AppendLine((Get-TextF -Key 'DetailsTargetInfo' -Arguments @($monitor.TargetResource, $matching.Count)))
                    foreach ($row in @($shown | Select-Object -First 3)) {
                        $logEntry = $row.Event
                        [void]$sb.AppendLine(('  [{0}] {1} ({2})' -f $logEntry.TimeCreated, $logEntry.LogName, $logEntry.Level))
                        $dupeSuffix = if ($row.Count -gt 1) { Get-TextF -Key 'DetailsDupes' -Arguments @($row.Count) } else { '' }
                        [void]$sb.AppendLine(('    {0}{1}' -f $logEntry.Message, $dupeSuffix))
                        if ($logEntry.Detail -and $logEntry.Detail -notmatch 'Error=\[null\].*Exception=\[null\]') {
                            [void]$sb.AppendLine(('    Detail: {0}' -f $logEntry.Detail))
                        }
                    }
                    if ($hiddenInfos -gt 0) {
                        [void]$sb.AppendLine((Get-TextF -Key 'DetailsHiddenInfo' -Arguments @($hiddenInfos)))
                    }
                }
            }
        }

        $disabledLogs = @($Result.Errors | Where-Object { [string]$_ -like '*LogIsEnabled=False*' })
        $otherErrors  = @($Result.Errors | Where-Object { [string]$_ -notlike '*LogIsEnabled=False*' })
        if ($disabledLogs.Count -gt 0 -and $errTotal -eq 0) {
            # Nur erwaehnen, wenn kein Fehler gefunden wurde (moegliche Erklaerung);
            # bei gefundenem Fehler ist der Hinweis nur Rauschen.
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((Get-Text -Key 'DetailsDisabledHint'))
        }
        $maDisabled = @($disabledLogs | Where-Object { [string]$_ -like '*ManagedAvailability*' }).Count -gt 0
        if ($maDisabled -and @($Result.Events | Where-Object { [string]$_.LogName -like '*ManagedAvailability*' }).Count -eq 0) {
            # Alle ManagedAvailability-Logs deaktiviert und keine Treffer: Reaktivierung anbieten.
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((Get-Text -Key 'DetailsEnableLogsHint'))
        }

        $errorsToShow = @($otherErrors)
        if (@($Result.Events).Count -eq 0) { $errorsToShow = @($Result.Errors) }
        if ($errorsToShow.Count -gt 0) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((Get-Text -Key 'DetailsErrors'))
            foreach ($message in $errorsToShow) {
                [void]$sb.AppendLine(('  - {0}' -f $message))
            }
        }

        $text = $sb.ToString()
        $Script:Ui['TxtDetails'].Text = $text
        $Script:State.DetailsBySet[[string]$Result.HealthSet] = $text
    } catch {
        Write-Log -Message ('Show-AnalyseResult: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}
#endregion

#region Admin-Aktionen (Re-Test, Override, Quick Fix)
<#
.SYNOPSIS
    Triggert die betroffenen Monitoring-Probes erneut (Invoke-MonitoringProbe).
#>
function Invoke-ReTest {
    [CmdletBinding()]
    param()
    try {
        $row = $Script:State.Selected
        if (-not $row) {
            Show-Error -Message (Get-Text -Key 'MsgNoSelection') -Level 'WARN'
            return
        }

        $retestScript = @'
param([string]$Server, [string]$HealthSet, [string]$Monitor)
$results = New-Object System.Collections.ArrayList
$items = @()

# Alle Monitoring-Items des HealthSets ermitteln (Identity = HealthSet-Name)
try {
    $items = @(Get-MonitoringItemIdentity -Identity $HealthSet -Server $Server -ErrorAction Stop)
} catch {
    [void]$results.Add([pscustomobject]@{ Identity = $HealthSet; Status = 'ERROR'; Result = ''; Error = ('Get-MonitoringItemIdentity: {0}' -f $_.Exception.Message) })
}

# Passende Probes zum Monitor waehlen (Monitorname ohne Suffix als Suchbasis)
$monitorBase = ([string]$Monitor) -replace '\.?(Monitor|Responder)$', ''
$probes = @($items | Where-Object { [string]$_.ItemType -eq 'Probe' -and ([string]$_.Name) -like ('*{0}*' -f $monitorBase) })
if (@($probes).Count -eq 0) {
    # Fallback nur bei wenigen Probes im HealthSet, um keine Massenausfuehrung zu starten
    $allProbes = @($items | Where-Object { [string]$_.ItemType -eq 'Probe' })
    if (@($allProbes).Count -le 3) { $probes = $allProbes }
    else {
        [void]$results.Add([pscustomobject]@{ Identity = $HealthSet; Status = 'ERROR'; Result = ''; Error = ('Keine Probe zum Monitor "{0}" gefunden (HealthSet {1})' -f $Monitor, $HealthSet) })
    }
}

foreach ($probe in $probes) {
    # Identity ist zweiteilig: HealthSet\ProbeName
    $identity = ''
    if ($probe.PSObject.Properties['Identity'] -and $probe.Identity) { $identity = [string]$probe.Identity }
    elseif ($probe.PSObject.Properties['Name'] -and $probe.Name)     { $identity = '{0}\{1}' -f $HealthSet, [string]$probe.Name }
    if ([string]::IsNullOrWhiteSpace($identity)) { continue }

    try {
        $probeResult = Invoke-MonitoringProbe -Identity $identity -Server $Server -ErrorAction Stop
        $value = ''
        foreach ($prop in @('ProbeResult', 'Result')) {
            if ($probeResult.PSObject.Properties[$prop] -and $probeResult.$prop) { $value = [string]$probeResult.$prop; break }
        }
        $errorText = ''
        foreach ($prop in @('Exception', 'Error')) {
            if ($probeResult.PSObject.Properties[$prop] -and $probeResult.$prop) { $errorText = [string]$probeResult.$prop; break }
        }
        [void]$results.Add([pscustomobject]@{ Identity = $identity; Status = 'OK'; Result = $value; Error = $errorText })
    } catch {
        [void]$results.Add([pscustomobject]@{ Identity = $identity; Status = 'ERROR'; Result = ''; Error = $_.Exception.Message })
    }
}
$results.ToArray()
'@

        $onDone = {
            param($out, $err)
            try {
                if (@($err).Count -gt 0) { Write-AsyncError -Errors $err }
                $items = @($out)
                $text = ($items | ForEach-Object { '{0}  [{1}] {2} {3}' -f $_.Identity, $_.Status, $_.Result, $_.Error }) -join "`r`n"
                Add-DetailsText -Text ("`r`n[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), (Get-Text -Key 'BtnRetest')) -Detail $text
                [void][System.Windows.MessageBox]::Show((Get-TextF -Key 'MsgRetestDone' -Arguments @($items.Count, $text)), (Get-Text -Key 'MsgTitle'), 'OK', 'Information')
                Write-Log -Message ('Re-Test ausgefuehrt: {0} Probe(s).' -f $items.Count)
                Start-HealthScan
            } catch {
                Write-Log -Message ('Re-Test-OnComplete: {0}' -f $_.Exception.Message) -Level 'ERROR'
            }
        }

        Start-AsyncTask -Script $retestScript -Parameters @{
            Server    = (Get-TargetServer)
            HealthSet = [string]$row.HealthSet
            Monitor   = [string]$row.Monitor
        } -OnComplete $onDone -BusyTextKey 'StatusRetesting'
    } catch {
        Write-Log -Message ('Invoke-ReTest: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Setzt fuer den markierten Check einen Server-Monitoring-Override (Stummschaltung).
#>
function Invoke-MonitoringOverride {
    [CmdletBinding()]
    param()
    try {
        $row = $Script:State.Selected
        if (-not $row) {
            Show-Error -Message (Get-Text -Key 'MsgNoSelection') -Level 'WARN'
            return
        }

        $identity = '{0}\{1}' -f $row.HealthSet, $row.Monitor
        $question = Get-TextF -Key 'MsgConfirmOverride' -Arguments @($identity, $Script:Config.OverrideDays)
        $answer   = [System.Windows.MessageBox]::Show($question, (Get-Text -Key 'MsgTitle'), 'YesNo', 'Question')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-Log -Message 'Override abgebrochen (keine Bestaetigung).' -Level 'DEBUG'
            return
        }

        $overrideScript = @'
param([string]$Server, [string]$Identity, [int]$Days)
$duration = New-TimeSpan -Days $Days
# PropertyValue wird von Add-ServerMonitoringOverride als String erwartet
$result = Add-ServerMonitoringOverride -Server $Server -Identity $Identity -ItemType Monitor -PropertyName Enabled -PropertyValue 'False' -Duration $duration -ErrorAction Stop
$result | Select-Object *
'@

        $onDone = {
            param($out, $err)
            try {
                if (@($err).Count -gt 0) { Write-AsyncError -Errors $err }
                $text = (@($out) | Format-List | Out-String).Trim()
                Add-DetailsText -Text ("`r`n[{0}] {1}: {2}" -f (Get-Date -Format 'HH:mm:ss'), (Get-Text -Key 'BtnOverride'), $text)
                [void][System.Windows.MessageBox]::Show((Get-TextF -Key 'MsgOverrideOk' -Arguments @($text)), (Get-Text -Key 'MsgTitle'), 'OK', 'Information')
                Write-Log -Message ('Override gesetzt: {0}' -f $text)
            } catch {
                Write-Log -Message ('Override-OnComplete: {0}' -f $_.Exception.Message) -Level 'ERROR'
            }
        }

        Start-AsyncTask -Script $overrideScript -Parameters @{
            Server   = (Get-TargetServer)
            Identity = $identity
            Days     = $Script:Config.OverrideDays
        } -OnComplete $onDone -BusyTextKey 'StatusOverride'
    } catch {
        Write-Log -Message ('Invoke-MonitoringOverride: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Startet den vom Monitor betroffenen Dienst bzw. IIS-AppPool nach Rueckfrage neu.
#>
function Invoke-QuickFix {
    [CmdletBinding()]
    param()
    try {
        $row = $Script:State.Selected
        if (-not $row) {
            Show-Error -Message (Get-Text -Key 'MsgNoSelection') -Level 'WARN'
            return
        }

        $server   = Get-TargetServer
        $target   = Get-QuickFixTarget -HealthSet $row.HealthSet -Monitor $row.Monitor -TargetResource $row.TargetResource
        $services = @($target.Services  | Where-Object { $_ } | Select-Object -Unique)
        $appPools = @($target.AppPools  | Where-Object { $_ } | Select-Object -Unique)

        if ($services.Count -eq 0 -and $appPools.Count -eq 0) {
            [void][System.Windows.MessageBox]::Show((Get-Text -Key 'MsgQuickFixNone'), (Get-Text -Key 'MsgTitle'), 'OK', 'Warning')
            Write-Log -Message ('Quick Fix: keine Komponente fuer {0}\{1} ermittelt.' -f $row.HealthSet, $row.Monitor) -Level 'WARN'
            return
        }

        $list = @()
        foreach ($pool in $appPools) { $list += ('AppPool : {0}' -f $pool) }
        foreach ($service in $services) { $list += ('Service : {0}' -f $service) }
        $listText = $list -join "`n"

        $question = Get-TextF -Key 'MsgQuickFixConfirm' -Arguments @($server, $listText)
        $answer   = [System.Windows.MessageBox]::Show($question, (Get-Text -Key 'MsgTitle'), 'YesNo', 'Question')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-Log -Message 'Quick Fix abgebrochen (keine Bestaetigung).' -Level 'DEBUG'
            return
        }

        $quickFixScript = @'
param([string]$Server, [string[]]$Services, [string[]]$AppPools)
$log = New-Object System.Collections.ArrayList
$localName = $env:COMPUTERNAME
$isRemote = $Server -and ($Server -ne $localName) -and ($Server -ne 'localhost') -and ($Server -ne '127.0.0.1')

# Dienste neu starten
foreach ($serviceName in $Services) {
    try {
        $service = Get-Service -ComputerName $Server -Name $serviceName -ErrorAction Stop
        Restart-Service -InputObject $service -Force -ErrorAction Stop
        [void]$log.Add(('OK      Service {0}: neu gestartet' -f $serviceName))
    } catch {
        [void]$log.Add(('FEHLER  Service {0}: {1}' -f $serviceName, $_.Exception.Message))
    }
}

# IIS-AppPools recyceln (lokal via WebAdministration, remote via Invoke-Command)
foreach ($poolName in $AppPools) {
    try {
        if ($isRemote) {
            Invoke-Command -ComputerName $Server -ArgumentList $poolName -ScriptBlock {
                param($PoolName)
                Import-Module WebAdministration -ErrorAction SilentlyContinue
                if (Get-Command -Name Restart-WebAppPool -ErrorAction SilentlyContinue) {
                    Restart-WebAppPool -Name $PoolName -ErrorAction Stop
                } else {
                    $appcmd = Join-Path $env:SystemRoot 'system32\inetsrv\appcmd.exe'
                    & $appcmd recycle apppool ('/apppool.name:' + $PoolName) | Out-Null
                }
            } -ErrorAction Stop
        } else {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            if (Get-Command -Name Restart-WebAppPool -ErrorAction SilentlyContinue) {
                Restart-WebAppPool -Name $poolName -ErrorAction Stop
            } else {
                $appcmd = Join-Path $env:SystemRoot 'system32\inetsrv\appcmd.exe'
                & $appcmd recycle apppool ('/apppool.name:' + $poolName) | Out-Null
            }
        }
        [void]$log.Add(('OK      AppPool {0}: recycelt' -f $poolName))
    } catch {
        [void]$log.Add(('FEHLER  AppPool {0}: {1}' -f $poolName, $_.Exception.Message))
    }
}
$log.ToArray()
'@

        $onDone = {
            param($out, $err)
            try {
                if (@($err).Count -gt 0) { Write-AsyncError -Errors $err }
                $text = (@($out) | ForEach-Object { [string]$_ }) -join "`r`n"
                Add-DetailsText -Text ("`r`n[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), (Get-Text -Key 'BtnQuickFix')) -Detail $text
                [void][System.Windows.MessageBox]::Show((Get-TextF -Key 'MsgQuickFixDone' -Arguments @($text)), (Get-Text -Key 'MsgTitle'), 'OK', 'Information')
                Write-Log -Message ('Quick Fix ausgefuehrt: {0}' -f $text)
                Start-HealthScan
            } catch {
                Write-Log -Message ('Quick-Fix-OnComplete: {0}' -f $_.Exception.Message) -Level 'ERROR'
            }
        }

        Start-AsyncTask -Script $quickFixScript -Parameters @{
            Server   = $server
            Services = $services
            AppPools = $appPools
        } -OnComplete $onDone -BusyTextKey 'StatusQuickFix'
    } catch {
        Write-Log -Message ('Invoke-QuickFix: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Haengt einen formatierten Block an die Detail-Textbox an.
#>
function Add-DetailsText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string]$Detail
    )
    try {
        if (-not $Script:Ui['TxtDetails']) { return }
        $block = if ($Detail) { '{0}{1}{2}{2}' -f $Text, "`r`n", $Detail } else { $Text }
        $Script:Ui['TxtDetails'].AppendText($block)
        $Script:Ui['TxtDetails'].ScrollToEnd()
    } catch {
        Write-Log -Message ('Add-DetailsText: {0}' -f $_.Exception.Message) -Level 'WARN'
    }
}
#endregion

#region HTML-Export
<#
.SYNOPSIS
    Maskiert Sonderzeichen fuer die HTML-Ausgabe.
#>
function ConvertTo-HtmlText {
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

<#
.SYNOPSIS
    Erzeugt das vollstaendige HTML-Dokument (CSS, Summary, Fehlertabelle, Details).
#>
function Get-HtmlReport {
    [CmdletBinding()]
    param(
        [object[]]$Rows,
        [string]$Server
    )
    try {
        $rows       = @($Rows)
        $allRows    = @($Script:State.HealthData)
        $total      = $allRows.Count
        $unhealthy  = $rows.Count
        $healthy    = [Math]::Max(0, $total - $unhealthy)
        $created    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $langCode   = if ($Script:Config.Language -eq 'DE') { 'de' } else { 'en' }

        $template = @'
<!DOCTYPE html>
<html lang="@@LANG@@">
<head>
<meta charset="utf-8"/>
<title>@@TITLE@@</title>
<style>
    body      { font-family: "Segoe UI", Arial, sans-serif; background: #f5f6f8; color: #222; margin: 0; padding: 24px; }
    h1        { color: #1f3b57; border-bottom: 3px solid #2d7dd2; padding-bottom: 8px; }
    h2        { color: #1f3b57; margin-top: 32px; }
    h3        { color: #333; margin-bottom: 4px; }
    .meta     { color: #555; font-size: 13px; margin-bottom: 16px; }
    .cards    { display: flex; gap: 16px; flex-wrap: wrap; margin: 16px 0; }
    .card     { background: #fff; border: 1px solid #dfe3e8; border-radius: 8px; padding: 14px 20px; min-width: 150px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
    .card .v  { font-size: 26px; font-weight: 600; }
    .card .l  { font-size: 12px; color: #666; text-transform: uppercase; letter-spacing: .5px; }
    .bad      { color: #b3261e; }
    .warn     { color: #a05a00; }
    .good     { color: #1e7a3c; }
    table     { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
    th, td    { border: 1px solid #dfe3e8; padding: 8px 10px; text-align: left; font-size: 13px; vertical-align: top; }
    th        { background: #1f3b57; color: #fff; }
    tr.unhealthy td { background: #fdecea; color: #8c1d18; }
    tr.degraded  td { background: #fff6e5; color: #8a5200; }
    pre       { background: #1e1e2e; color: #e6e6e6; padding: 14px; border-radius: 8px; overflow-x: auto; font-size: 12px; line-height: 1.45; }
    footer    { margin-top: 32px; color: #777; font-size: 12px; border-top: 1px solid #dfe3e8; padding-top: 10px; }
</style>
</head>
<body>
<h1>@@TITLE@@</h1>
<div class="meta">@@SERVER@@: <strong>@@SERVERNAME@@</strong> &nbsp;|&nbsp; @@CREATED@@: @@CREATEDVALUE@@</div>

<h2>@@SUMMARY@@</h2>
<div class="cards">
    <div class="card"><div class="v">@@TOTALVALUE@@</div><div class="l">@@TOTALLABEL@@</div></div>
    <div class="card"><div class="v bad">@@UNHEALTHYVALUE@@</div><div class="l">@@UNHEALTHYLABEL@@</div></div>
    <div class="card"><div class="v good">@@HEALTHYVALUE@@</div><div class="l">@@HEALTHYLABEL@@</div></div>
</div>

<h2>@@UNHEALTHYLABEL@@</h2>
@@TABLE@@

<h2>@@DETAILSLABEL@@</h2>
@@DETAILS@@

<footer>@@FOOTER@@</footer>
</body>
</html>
'@

        # Tabelle der ungesunden Checks aufbauen
        $tableBuilder = New-Object System.Text.StringBuilder
        if ($unhealthy -eq 0) {
            [void]$tableBuilder.AppendLine(('<p><em>{0}</em></p>' -f (ConvertTo-HtmlText (Get-Text -Key 'HtmlNoIssues'))))
        } else {
            [void]$tableBuilder.AppendLine('<table>')
            [void]$tableBuilder.AppendLine(('<thead><tr><th>{0}</th><th>{1}</th><th>{2}</th><th>{3}</th><th>{4}</th></tr></thead>' -f `
                (ConvertTo-HtmlText (Get-Text -Key 'ColHealthSet')), (ConvertTo-HtmlText (Get-Text -Key 'ColMonitor')), `
                (ConvertTo-HtmlText (Get-Text -Key 'ColAlert')), (ConvertTo-HtmlText (Get-Text -Key 'ColChanged')), `
                (ConvertTo-HtmlText (Get-Text -Key 'ColTarget'))))
            [void]$tableBuilder.AppendLine('<tbody>')
            foreach ($row in $rows) {
                $alert = Get-AlertText -Value $row.AlertValue
                $cssClass = switch ($alert) {
                    'Unhealthy' { 'unhealthy' }
                    'Degraded'  { 'degraded' }
                    default     { '' }
                }
                [void]$tableBuilder.AppendLine(('<tr class="{0}"><td>{1}</td><td>{2}</td><td><strong>{3}</strong></td><td>{4}</td><td>{5}</td></tr>' -f `
                    $cssClass, (ConvertTo-HtmlText $row.HealthSet), (ConvertTo-HtmlText $row.Monitor), (ConvertTo-HtmlText $alert), `
                    (ConvertTo-HtmlText $row.LastTransitionTime), (ConvertTo-HtmlText $row.TargetResource)))
            }
            [void]$tableBuilder.AppendLine('</tbody>')
            [void]$tableBuilder.AppendLine('</table>')
        }

        # Detailbloecke (nur fuer bereits analysierte HealthSets)
        $detailsBuilder = New-Object System.Text.StringBuilder
        $detailSets = @($rows | ForEach-Object { [string]$_.HealthSet } | Select-Object -Unique)
        $foundDetails = $false
        foreach ($healthSet in $detailSets) {
            if ($Script:State.DetailsBySet.ContainsKey($healthSet)) {
                $foundDetails = $true
                [void]$detailsBuilder.AppendLine(('<h3>{0}</h3>' -f (ConvertTo-HtmlText $healthSet)))
                [void]$detailsBuilder.AppendLine(('<pre>{0}</pre>' -f (ConvertTo-HtmlText $Script:State.DetailsBySet[$healthSet])))
            }
        }
        if (-not $foundDetails) {
            [void]$detailsBuilder.AppendLine(('<p><em>{0}</em></p>' -f (ConvertTo-HtmlText (Get-Text -Key 'DetailsPlaceholder'))))
        }

        $html = $template
        $replacements = @{
            '@@LANG@@'            = $langCode
            '@@TITLE@@'           = ConvertTo-HtmlText (Get-Text -Key 'HtmlTitle')
            '@@SERVER@@'          = ConvertTo-HtmlText (Get-Text -Key 'HtmlServer')
            '@@SERVERNAME@@'      = ConvertTo-HtmlText $Server
            '@@CREATED@@'         = ConvertTo-HtmlText (Get-Text -Key 'HtmlCreated')
            '@@CREATEDVALUE@@'    = $created
            '@@SUMMARY@@'         = ConvertTo-HtmlText (Get-Text -Key 'HtmlSummary')
            '@@TOTALLABEL@@'      = ConvertTo-HtmlText (Get-Text -Key 'HtmlTotal')
            '@@UNHEALTHYLABEL@@'  = ConvertTo-HtmlText (Get-Text -Key 'HtmlUnhealthy')
            '@@HEALTHYLABEL@@'    = ConvertTo-HtmlText (Get-Text -Key 'HtmlHealthy')
            '@@TOTALVALUE@@'      = $total
            '@@UNHEALTHYVALUE@@'  = $unhealthy
            '@@HEALTHYVALUE@@'    = $healthy
            '@@TABLE@@'           = $tableBuilder.ToString()
            '@@DETAILSLABEL@@'    = ConvertTo-HtmlText (Get-Text -Key 'HtmlDetails')
            '@@DETAILS@@'         = $detailsBuilder.ToString()
            '@@FOOTER@@'          = ConvertTo-HtmlText (Get-TextF -Key 'HtmlFooter' -Arguments @($Script:Config.AppVersion))
        }
        foreach ($token in $replacements.Keys) {
            $html = $html.Replace($token, [string]$replacements[$token])
        }
        return $html
    } catch {
        Write-Log -Message ('Get-HtmlReport: {0}' -f $_.Exception.Message) -Level 'ERROR'
        throw
    }
}

<#
.SYNOPSIS
    Speichert den HTML-Report ueber einen Datei-Dialog.
#>
function Export-HtmlReportInteractive {
    [CmdletBinding()]
    param()
    try {
        if (@($Script:State.HealthData).Count -eq 0) {
            Show-Error -Message (Get-Text -Key 'MsgNoData') -Level 'WARN'
            return
        }

        $server = Get-TargetServer
        Set-Status -Key 'StatusExporting'
        $html = Get-HtmlReport -Rows $Script:State.Unhealthy -Server $server

        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Title            = Get-Text -Key 'DlgSaveTitle'
        $dialog.Filter           = Get-Text -Key 'DlgHtmlFilter'
        $dialog.AddExtension     = $true
        $dialog.DefaultExt       = 'html'
        $dialog.FileName         = 'Exchange-HealthReport_{0}_{1:yyyyMMdd_HHmm}.html' -f $server, (Get-Date)

        if ($dialog.ShowDialog() -eq $true) {
            [System.IO.File]::WriteAllText($dialog.FileName, $html, (New-Object System.Text.UTF8Encoding($false)))
            Write-Log -Message ('HTML-Report gespeichert: {0}' -f $dialog.FileName)
            Set-Status -Key 'StatusReady'
            [void][System.Windows.MessageBox]::Show((Get-TextF -Key 'MsgExportOk' -Arguments @($dialog.FileName)), (Get-Text -Key 'MsgTitle'), 'OK', 'Information')
        } else {
            Set-Status -Key 'StatusReady'
        }
    } catch {
        Write-Log -Message ('Export-HtmlReportInteractive: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}
#endregion

#region Mailversand
<#
.SYNOPSIS
    Zeigt den Mail-Dialog und versendet den HTML-Report asynchron per SMTP.
#>
function Show-MailDialog {
    [CmdletBinding()]
    param()
    try {
        if (@($Script:State.HealthData).Count -eq 0) {
            Show-Error -Message (Get-Text -Key 'MsgNoData') -Level 'WARN'
            return
        }

        # Farben der aktiven Darstellung in die XAML-Platzhalter schreiben
        $xaml = $Script:MailXaml
        $xaml = $xaml.Replace('{{BG}}',    (Get-ThemeColor -Key 'WindowBg'))
        $xaml = $xaml.Replace('{{FG}}',    (Get-ThemeColor -Key 'TextFg'))
        $xaml = $xaml.Replace('{{INPUT}}', (Get-ThemeColor -Key 'InputBg'))
        $xaml = $xaml.Replace('{{LINE}}',  (Get-ThemeColor -Key 'LineBrush'))

        # Lokalisierte Texte in die XAML-Platzhalter schreiben
        $mailTexts = @{
            '{{TITLE}}'      = (Get-Text -Key 'MailTitle')
            '{{LBL_SMTP}}'   = (Get-Text -Key 'MailSmtp')
            '{{LBL_PORT}}'   = (Get-Text -Key 'MailPort')
            '{{LBL_SSL}}'    = (Get-Text -Key 'MailSsl')
            '{{LBL_FROM}}'   = (Get-Text -Key 'MailFrom')
            '{{LBL_TO}}'     = (Get-Text -Key 'MailTo')
            '{{LBL_SUBJECT}}'= (Get-Text -Key 'MailSubject')
            '{{BTN_SEND}}'   = (Get-Text -Key 'BtnSend')
            '{{BTN_CANCEL}}' = (Get-Text -Key 'BtnCancel')
        }
        foreach ($token in $mailTexts.Keys) {
            $xaml = $xaml.Replace($token, ([string]$mailTexts[$token] -replace '&', '&amp;'))
        }

        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $window.Owner = $Script:Ui['Window']

        $Script:MailUi = @{ Window = $window }
        foreach ($name in @('TxtSmtp', 'TxtPort', 'ChkSsl', 'TxtFrom', 'TxtTo', 'TxtSubject', 'BtnSend', 'BtnCancel')) {
            $Script:MailUi[$name] = $window.FindName($name)
        }

        # Vorbelegung aus der Konfiguration
        $Script:MailUi['TxtSmtp'].Text    = $Script:Config.MailDefaults.SmtpServer
        $Script:MailUi['TxtPort'].Text    = [string]$Script:Config.MailDefaults.Port
        $Script:MailUi['ChkSsl'].IsChecked = [bool]$Script:Config.MailDefaults.UseSsl
        $Script:MailUi['TxtFrom'].Text    = $Script:Config.MailDefaults.From
        $Script:MailUi['TxtTo'].Text      = $Script:Config.MailDefaults.To
        $Script:MailUi['TxtSubject'].Text = '{0} - {1} ({2:yyyy-MM-dd HH:mm})' -f $Script:Config.MailDefaults.Subject, (Get-Text -Key 'HtmlUnhealthy'), (Get-Date)

        $Script:MailUi['BtnSend'].Add_Click({
            try { Send-ReportMail } catch { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) }
        })
        $Script:MailUi['BtnCancel'].Add_Click({ try { $Script:MailUi['Window'].Close() } catch { } })

        [void]$window.ShowDialog()
    } catch {
        Write-Log -Message ('Show-MailDialog: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Validiert die Eingaben und versendet den HTML-Report asynchron.
#>
function Send-ReportMail {
    [CmdletBinding()]
    param()
    try {
        $ui = $Script:MailUi
        if (-not $ui) { return }

        $recipients = @($ui['TxtTo'].Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $from       = $ui['TxtFrom'].Text.Trim()
        if ($recipients.Count -eq 0 -or [string]::IsNullOrWhiteSpace($from)) {
            [void][System.Windows.MessageBox]::Show((Get-Text -Key 'MsgMailIncomplete'), (Get-Text -Key 'MsgTitle'), 'OK', 'Warning')
            return
        }

        $smtpServer = $ui['TxtSmtp'].Text.Trim()
        $port       = 25
        [void][int]::TryParse($ui['TxtPort'].Text.Trim(), [ref]$port)
        if ($port -le 0) { $port = 25 }
        $useSsl     = [bool]$ui['ChkSsl'].IsChecked
        $subject    = $ui['TxtSubject'].Text
        $body       = Get-HtmlReport -Rows $Script:State.Unhealthy -Server (Get-TargetServer)

        # Werte sichern, damit der Dialog bei erneutem Senden vorbelegt bleibt
        $Script:Config.MailDefaults.SmtpServer = $smtpServer
        $Script:Config.MailDefaults.Port       = $port
        $Script:Config.MailDefaults.UseSsl     = $useSsl
        $Script:Config.MailDefaults.From       = $from
        $Script:Config.MailDefaults.To         = $ui['TxtTo'].Text.Trim()
        $Script:Config.MailDefaults.Subject    = $subject

        # Empfaenger im Skriptscope ablegen, da der Async-Handler spaeter ausserhalb
        # des Funktionsscopes ausgefuehrt wird
        $Script:MailRecipients = $recipients

        $mailScript = @'
param([string]$SmtpServer, [int]$Port, [bool]$UseSsl, [string]$From, [string[]]$To, [string]$Subject, [string]$Body)
$mail   = $null
$client = $null
try {
    $mail = New-Object System.Net.Mail.MailMessage
    $mail.From = New-Object System.Net.Mail.MailAddress($From)
    foreach ($recipient in $To) { [void]$mail.To.Add($recipient) }
    $mail.Subject    = $Subject
    $mail.Body       = $Body
    $mail.IsBodyHtml = $true

    $client = New-Object System.Net.Mail.SmtpClient($SmtpServer, $Port)
    $client.EnableSsl = $UseSsl
    $client.Send($mail)
    'MAIL-SENT'
} finally {
    if ($client) { $client.Dispose() }
    if ($mail)   { $mail.Dispose() }
}
'@

        $onDone = {
            param($out, $err)
            try {
                # Buttons wieder freigeben, damit der Dialog bei Fehlern nutzbar bleibt
                if ($Script:MailUi['BtnSend'])   { $Script:MailUi['BtnSend'].IsEnabled   = $true }
                if ($Script:MailUi['BtnCancel']) { $Script:MailUi['BtnCancel'].IsEnabled = $true }

                if (@($err).Count -gt 0) {
                    Write-AsyncError -Errors $err
                    Set-Status -Key 'StatusReady'
                    return
                }
                $receiverList = @($Script:MailRecipients) -join ', '
                Write-Log -Message ('Report per Mail gesendet an {0}.' -f $receiverList)
                [void][System.Windows.MessageBox]::Show((Get-TextF -Key 'MsgMailOk' -Arguments @($receiverList)), (Get-Text -Key 'MsgTitle'), 'OK', 'Information')
                Set-Status -Key 'StatusReady'
                if ($Script:MailUi['Window']) { $Script:MailUi['Window'].Close() }
            } catch {
                Write-Log -Message ('Send-ReportMail-OnComplete: {0}' -f $_.Exception.Message) -Level 'ERROR'
            }
        }

        Set-Status -Key 'StatusSendingMail'
        $ui['BtnSend'].IsEnabled   = $false
        $ui['BtnCancel'].IsEnabled = $false
        Start-AsyncTask -Script $mailScript -Parameters @{
            SmtpServer = $smtpServer
            Port       = $port
            UseSsl     = $useSsl
            From       = $from
            To         = $recipients
            Subject    = $subject
            Body       = $body
        } -OnComplete $onDone -BusyTextKey 'StatusSendingMail' -UseLocalRunspace
    } catch {
        Write-Log -Message ('Send-ReportMail: {0}' -f $_.Exception.Message) -Level 'ERROR'
        if ($Script:MailUi['BtnSend'])   { $Script:MailUi['BtnSend'].IsEnabled   = $true }
        if ($Script:MailUi['BtnCancel']) { $Script:MailUi['BtnCancel'].IsEnabled = $true }
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
    }
}
#endregion

#region Initialisierung / Hauptprogramm
<#
.SYNOPSIS
    Prueft Voraussetzungen, legt Logverzeichnis an und erstellt die Runspaces.
#>
function Initialize-Application {
    [CmdletBinding()]
    param()
    try {
        Initialize-LogDirectory
        Initialize-WpfAssemblies
        Write-Log -Message ('Start Exchange HealthReport Analyzer v{0}' -f $Script:Config.AppVersion)
        Write-Log -Message ('Zielserver: {0} | Log: {1}' -f $Script:Config.TargetServer, $Script:Config.LogFile)

        if (-not (Test-Administrator)) {
            [void][System.Windows.MessageBox]::Show('Administratorrechte erforderlich. Bitte PowerShell als Administrator starten.', (Get-Text -Key 'MsgTitle'), 'OK', 'Error')
            Write-Log -Message 'Abbruch: keine Administratorrechte.' -Level 'ERROR'
            return $false
        }

        # WPF benoetigt STA - bei MTA startet das Skript sich selbst neu
        if (-not (Test-StaApartment)) {
            Write-Log -Message 'Neustart in STA-Instanz angefordert.' -Level 'WARN'
            return $false
        }

        Initialize-Runspaces
        return $true
    } catch {
        Write-Log -Message ('Initialize-Application: {0}' -f $_.Exception.Message) -Level 'ERROR'
        Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message))
        return $false
    }
}

# --- Hauptablauf -------------------------------------------------------------
try {
    if (Initialize-Application) {
        Show-MainWindow
    }
} catch {
    Write-Log -Message ('Hauptprogramm: {0}' -f $_.Exception.Message) -Level 'ERROR'
    try { Show-Error -Message (Get-TextF -Key 'ErrGeneric' -Arguments @($_.Exception.Message)) } catch { Write-Host $_.Exception.Message }
} finally {
    Close-AsyncTasks
    Close-Runspaces
    Write-Log -Message 'Skript beendet.'
}
#endregion
