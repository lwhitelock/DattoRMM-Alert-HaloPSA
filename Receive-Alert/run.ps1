using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

Write-Host "Processing Webhook for Alert $($Request.Body.alertUID)"

$HaloClientID = $env:HaloClientID
$HaloClientSecret = $env:HaloClientSecret
$HaloURL = $env:HaloURL

$HaloTicketStatusID = $env:HaloTicketStatusID
$HaloCustomAlertTypeField = $env:HaloCustomAlertTypeField
$HaloTicketType = $env:HaloTicketType
$HaloReocurringStatus = $env:HaloReocurringStatus

# Set if the ticket will be marked as responded in Halo
$SetTicketResponded = $True

# Relates the tickets in Halo if the alerts arrive within x minutes for a device.
$RelatedAlertMinutes = 5

# Creates a child ticket in Halo off the main ticket if it reocurrs with the specified number of hours.
$ReoccurringTicketHours = 24

$HaloAlertHistoryDays = 90



$PriorityHaloMap = @{
    "Critical"    = "1"
    "High"        = "2"
    "Moderate"    = "3"
    "Low"         = "4"
    "Information" = "4"
}

$AlertWebhook = $Request.Body | convertfrom-json -depth 100


$Email = Get-AlertEmailBody -AlertWebhook $AlertWebhook

if ($Email) {
    $Alert = $Email.Alert

    Connect-HaloAPI -URL $HaloURL -ClientId $HaloClientID -ClientSecret $HaloClientSecret -Scopes "all"
    
    $HaloDeviceReport = @{
        name                    = "Datto RMM Improved Alerts PowerShell Function - Device Report"
        sql                     = "Select did, Dsite, DDattoID, DDattoAlternateId from device"
        description             = "This report is used to quickly obtain device mapping information for use with the improved Datto RMM Alerts Function"
        type                    = 0
        datasource_id           = 0
        canbeaccessedbyallusers = $false
    }

    $ParsedAlertType = Get-AlertHaloType -Alert $Alert -AlertMessage $AlertWebhook.alertMessage

    $HaloDevice = Invoke-HaloReport -Report $HaloDeviceReport -IncludeReport | where-object { $_.DDattoID -eq $Alert.alertSourceInfo.deviceUid }

    $HaloAlertsReportBase = @{
        name                    = "Datto RMM Improved Alerts PowerShell Function - Alerts Report"
        sql                     = "SELECT Faultid, Symptom, tstatusdesc, dateoccured, inventorynumber, FGFIAlertType, CFDattoAlertType, fxrefto as ParentID, fcreatedfromid as RelatedID FROM FAULTS inner join TSTATUS on Status = Tstatus Where CFDattoAlertType is not null and fdeleted <> 1"
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
        tickettype_id    = $HaloTicketType
        inventory_number = $HaloDevice.did
        details_html     = $HtmlBody
        gfialerttype     = $AlertID
        DattoAlertState = 0
        site_id          = $HaloDevice.dsite
        assets           = @(@{id = $HaloDevice.did })
        priority_id      = $HaloPriority
        status_id        = $HaloTicketStatusID
        customfields     = @(
            @{
                id    = $HaloCustomAlertTypeField
                value = $ParsedAlertType
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
            status_id = $HaloReocurringStatus   
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
