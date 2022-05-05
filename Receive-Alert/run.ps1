using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

Write-Host "Processing Webhook for Alert $($Request.Body.alertUID)"

$DattoURL = $env:DattoURL
$DattoKey = $env:DattoKey
$DattoSecretKey = $env:DattoSecretKey

$HaloClientID = $env:HaloClientID
$HaloClientSecret = $env:HaloClientSecret
$HaloURL = $env:HaloURL

$NumberOfColumns = 2
$HaloTicketStatusID = 2

# Relates the tickets in Halo if the alerts arrive within x minutes for a device.
$RelatedAlertMinutes = 5

# Creates a child ticket in Halo off the main ticket if it reocures with the specified number of hours.
$ReoccurringTicketHours = 24

$HaloReocurringStatus = 35

$HaloAlertHistoryDays = 90

#$HaloCustomAlertTypeField = $env:HaloCustomAlertTypeField
#$HaloDattoRMMDeviceLookup = $env:HaloDattoRMMDeviceLookup
#$HaloDattoRMMAlerts = $env:HaloDattoRMMAlerts
#$HaloTicketType = $env:HaloTicketType

$HaloCustomAlertTypeField = 252
$HaloDattoRMMDeviceLookup = 222
$HaloDattoRMMAlerts = 221
$HaloTicketType = 24

#$CPUUDF = $env:CPUUDF
#$RAMUDF = $env:RAMUDF

$CPUUDF = '29'
$RAMUDF = '30'

$PriorityHaloMap = @{
    "Critical"    = "1"
    "High"        = "2"
    "Moderate"    = "3"
    "Low"         = "4"
    "Information" = "4"
}


$AlertWebhook = $Request.Body

#$AlertTroubleshooting = $AlertWebhook.troubleshootingNote
#$AlertDocumentationURL = $AlertWebhook.docURL
#$ShowDeviceDetails = $AlertWebhook.showDeviceDetails
#$ShowDeviceStatus = $AlertWebhook.showDeviceStatus
#$ShowAlertDetails = $AlertWebhook.showAlertDetails
#$AlertID = $AlertWebhook.alertUID
#$AlertMessage = $AlertWebhook.alertMessage
#$DattoPlatform = $AlertWebhook.platform

$AlertTroubleshooting = 'Example Note'
$AlertDocumentationURL = 'https://docs.example.com'
$ShowDeviceDetails = $true
$ShowDeviceStatus = $true
$ShowAlertDetails = $true
$AlertID = 'e01e5dbb-6bc4-427c-b1f6-4106797af0ad'
$AlertMessage = '[Failure Test Monitor] - Result: A Test Alert Was Created'
$DattoPlatform = 'merlot'


$AlertTypesLookup = @{
    perf_resource_usage_ctx   = 'Resource Monitor'
    comp_script_ctx           = 'Component Monitor'
    perf_mon_ctx              = 'Performance Monitor'
    online_offline_status_ctx = 'Offline'
    eventlog_ctx              = 'Event Log'
    perf_disk_usage_ctx       = 'Disk Usage'
    patch_ctx                 = 'Patch Monitor'
    srvc_status_ctx           = 'Service Status'
    antivirus_ctx             = 'Antivirus'
    custom_snmp_ctx           = 'SNMP'
}



$params = @{
    Url       = $DattoURL
    Key       = $DattoKey
    SecretKey = $DattoSecretKey
}

Set-DrmmApiParameters @params

$Alert = Get-DrmmAlert -alertUid $AlertID

if ($Alert) {

    Connect-HaloAPI -URL $HaloURL -ClientId $HaloClientID -ClientSecret $HaloClientSecret -Scopes "all"
    

    [System.Collections.Generic.List[PSCustomObject]]$Sections = @()

    $Device = Get-DrmmDevice -deviceUid $Alert.alertSourceInfo.deviceUid
    $DeviceAudit = Get-DrmmAuditDevice -deviceUid $Alert.alertSourceInfo.deviceUid

    $HaloDevice = (Get-HaloReport -ReportID $HaloDattoRMMDeviceLookup -LoadReport).report.rows | where-object { $_.DDattoID -eq $Alert.alertSourceInfo.deviceUid }

    $ParsedAlertType = Get-AlertHaloType -Alert $Alert -AlertMessage $AlertMessage

    $AlertReportFilter = @{
        id = $HaloDattoRMMAlerts
        filters = @(
            @{
                fieldname = 'inventorynumber'
                stringruletype = 2
                stringruletext = "$($HaloDevice.did)"
            }
        )
        _loadreportonly = $true
        reportingperiodstartdate = get-date(((Get-date).ToUniversalTime()).adddays(-$HaloAlertHistoryDays)) -UFormat '+%Y-%m-%dT%H:%M:%SZ'
        reportingperiodenddate =  get-date((Get-date -Hour 23 -Minute 59 -second 59).ToUniversalTime()) -UFormat '+%Y-%m-%dT%H:%M:%SZ'
        reportingperioddatefield = "dateoccured"
        reportingperiod = "7"
    }

    $ReportResults = Set-HaloReport -Report $AlertReportFilter

    # Generate Email Subject

    Get-DRMMAlertDetailsSection -Sections $Sections -Alert $Alert -Device $Device -AlertDocumentationURL $AlertDocumentationURL -AlertTroubleshooting $AlertTroubleshooting -DattoPlatform $DattoPlatform


    ## Build the device details section if enabled.
    #if ($ShowDeviceDetails -eq $True) {
    #    Get-DRMMDeviceDetailsSection -Sections $Sections -Device $Device
    #}


    # Build the device status section if enabled
    if ($ShowDeviceStatus) {
        Get-DRMMDeviceStatusSection -Sections $Sections -Device $Device -DeviceAudit $DeviceAudit -CPUUDF $CPUUDF -RAMUDF $RAMUDF
    }


    if ($showAlertDetails -eq $true) {
        Get-DRMMAlertHistorySection -Sections $Sections -Alert $Alert -DattoPlatform $DattoPlatform
    }

    $TicketSubject = "Alert: $($AlertTypesLookup[$Alert.alertContext.'@class']) - $($AlertMessage) on device: $($Device.hostname)"

    $HTMLBody = Get-HTMLBody -Sections $Sections -NumberOfColumns $NumberOfColumns

    $HTMLBody | out-file c:\temp\HaloTest.html

    $HaloPriority = $PriorityHaloMap."$($Alert.Priority)"


    $HaloTicketCreate = @{
        summary          = $TicketSubject
        tickettype_id    = $HaloTicketType
        inventory_number = $HaloDevice.did
        details_html     = $HtmlBody
        gfialerttype     = $AlertID
        site_id          = $HaloDevice.dsite
        assets           = @(@{id = $HaloDevice.did })
        priority_id      = $HaloPriority
        status_id        = $HaloTicketStatusID
        customfields = @(
            @{
                id = $HaloCustomAlertTypeField
                value = $ParsedAlertType
            }
        )
    }

    $Ticket = New-HaloTicket -Ticket $HaloTicketCreate

    $ActionUpdate = @{
        id        = 1
        ticket_id = $Ticket.id
        important = $true
    }

    $Action = Set-HaloAction -Action $ActionUpdate

} else {
    Write-Host "No alert found"
}



# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ''
    })
