using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$FullRequest = $Request.Body | ConvertTo-Json | ConvertFrom-Json

<# $Full Request contents (for testing)
@{
    alertMessage        = "Process 'AdobeARMservice' isStopped" 
    showDeviceDetails   = "True"
    platform            = "Pinotage"
    alertUID            = "b1e3fba7-dfa8-480d-91a5-6e589a69c6d0" 
    docURL              = "https://www.troubleshootingcentral.com/high-memory-usage-on-windows-10-causes-and-fixes/"
    showAlertDetails    = "True"
    showDeviceStatus    = "True"
    troubleshootingNote = "Please check the system uptime, if excessive, advise the user to reboot the device."
}
#>

Write-Host "Processing Webhook for Alert - $($Request.Body.alertUID)"

$HaloClientID = "8f8f6226-2324-4d52-8c06-987c718edaa3"
$HaloClientSecret = "8a6bc9cd-6d66-4500-8a7e-c77c55456b97-fa283f4a-133c-40f4-9326-d0f2ee0fb88c"
$HaloURL = "https://alphascan.halopsa.com:443/"

# Set if the ticket will be marked as responded in Halo
$SetTicketResponded = $false

# Relates the tickets in Halo if the alerts arrive within x minutes for a device.
$RelatedAlertMinutes = 5

# Creates a child ticket in Halo off the main ticket if it reocurrs with the specified number of hours.
$ReoccurringTicketHours = 2

$HaloAlertHistoryDays = 90

$PriorityHaloMap = @{
    "Critical"    = "1"
    "High"        = "2"
    "Moderate"    = "3"
    "Low"         = "4"
    "Information" = "4"
}

$AlertWebhook = $FullRequest | ConvertTo-Json

$Email = Get-AlertEmailBody -AlertWebhook $FullRequest

if ($Email) {
    $Alert = $Email.Alert

    Connect-HaloAPI -URL $HaloURL -ClientId $HaloClientID -ClientSecret $HaloClientSecret -Scopes "all"
    
    $HaloDeviceReport = @{
        name                    = "Datto RMM Improved Alerts PowerShell Function - Device Report"
        sql                     = "Select did, Dsite, DDattoID, DDattoAlternateId, dinvno, dtype from device"
        description             = "This report is used to quickly obtain device mapping information for use with the improved Datto RMM Alerts Function"
        type                    = 0
        datasource_id           = 0
        canbeaccessedbyallusers = $false
    }

    $ParsedAlertType = Get-AlertHaloType -Alert $Alert -AlertMessage $AlertWebhook.alertMessage

    $HaloDevice = Invoke-HaloReport -Report $HaloDeviceReport -IncludeReport | where-object { $_.DDattoID -eq $Alert.alertSourceInfo.deviceUid }

    $HaloAlertsReportBase = @{
        name                    = "Datto RMM Improved Alerts PowerShell Function - Alerts Report"
        sql                     = "SELECT Faultid, Symptom, tstatusdesc, dateoccured, inventorynumber, CFDattoAlertType, fxrefto as ParentID, fcreatedfromid as RelatedID FROM FAULTS inner join TSTATUS on Status = Tstatus Where CFDattoAlertType is not null and fdeleted <> 1"
        description             = "This report is used to quickly obtain alert information for use with the improved Datto RMM Alerts Function"
        type                    = 0
        datasource_id           = 0
        canbeaccessedbyallusers = $false
    }

    $HaloAlertsReport = Invoke-HaloReport -Report $HaloAlertsReportBase

    $AlertReportFilter = @{
        id                       = $HaloAlertsReport.id
        filters                  = @(
            @{
                fieldname      = 'inventorynumber'
                stringruletype = 2
                stringruletext = "$($HaloDevice.did)"
            }
        )
        _loadreportonly          = $true
        reportingperiodstartdate = get-date(((Get-date).ToUniversalTime()).adddays(-$HaloAlertHistoryDays)) -UFormat '+%Y-%m-%dT%H:%M:%SZ'
        reportingperiodenddate   = get-date((Get-date -Hour 23 -Minute 59 -second 59).ToUniversalTime()) -UFormat '+%Y-%m-%dT%H:%M:%SZ'
        reportingperioddatefield = "dateoccured"
        reportingperiod          = "7"
    }

    $ReportResults = (Set-HaloReport -Report $AlertReportFilter).report.rows

    $ReoccuringHistory = $ReportResults | where-object { $_.CFDattoAlertType -eq $ParsedAlertType } 
    
    $ReoccuringAlerts = $ReoccuringHistory | where-object { $_.dateoccured -gt ((Get-Date).addhours(-$ReoccurringTicketHours)) }

    $RelatedAlerts = $ReportResults | where-object { $_.dateoccured -gt ((Get-Date).addminutes(-$RelatedAlertMinutes)).ToUniversalTime() -and $_.CFDattoAlertType -ne $ParsedAlertType }
        
    $TicketSubject = $Email.Subject

    $HTMLBody = $Email.Body

    $HaloPriority = $PriorityHaloMap."$($Alert.Priority)"

    $HaloTicketCreate = @{
        summary          = $TicketSubject
        tickettype_id    = 21
        inventory_number = $HaloDevice.did
        details_html     = $HtmlBody
        site_id          = $HaloDevice.dsite
        assets           = @(@{id = $HaloDevice.did })
        priority_id      = $HaloPriority
        status_id        = 1
        customfields     = @(
            @{
                id       = 202
                value    = $ParsedAlertType
            }
            @{
                id       = 210
                value    = $FullRequest.alertUID
            }
        )
    }

    # Handle reoccurring alerts
    if ($ReoccuringAlerts) {        
        $ReoccuringAlertParent = $ReoccuringAlerts | Sort-Object FaultID | Select-Object -First 1
                
        if ($ReoccuringAlertParent.ParentID) {
            $ParentID = $ReoccuringAlertParent.ParentID
        } else {
            $ParentID = $ReoccuringAlertParent.FaultID
        }
        
        $RecurringUpdate = @{
            id        = $ParentID
            status_id = 30
        }

        $null = Set-HaloTicket -Ticket $RecurringUpdate

        $HaloTicketCreate.add('parent_id', $ParentID)
        
    } elseif ($RelatedAlerts) {
        $RelatedAlertsParent = $RelatedAlerts | Sort-Object FaultID | Select-Object -First 1

        if ($RelatedAlertsParent.RelatedID -ne 0) {
            $CreatedFromID = $RelatedAlertsParent.RelatedID
        } else {
            $CreatedFromID = $RelatedAlertsParent.FaultID
        }
        
        $HaloTicketCreate.add('createdfrom_id', $CreatedFromID)

    } 

    $Ticket = New-HaloTicket -Ticket $HaloTicketCreate

    $ActionUpdate = @{
        id                = 1
        ticket_id         = $Ticket.id
        important         = $true
        action_isresponse = $true      
    }

    $Null = Set-HaloAction -Action $ActionUpdate

    if ($SetTicketResponded -eq $true) {
        $ActionResolveUpdate = @{
            ticket_id         = $Ticket.id
            action_isresponse = $true
            validate_response = $True
            sendemail         = $false
        }
        $Null = New-HaloAction -Action $ActionResolveUpdate
    }

} else {
    Write-Host "No alert found"
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ''
    })
