function Invoke-HaloReport {
    param (
        $Report,
        [Switch]$IncludeReport
    )
	# This will check for a Halo report. Create it if it doesn't exist and return the results if it does
	$HaloReportBase = Get-HaloReport -Search $report.name
	$FoundReportCount = ($HaloReportBase | Measure-Object).Count

	if ($FoundReportCount -eq 0) {
		$HaloReportBase = New-HaloReport -Report $report
	} elseif ($FoundReportCount -gt 1) {
		throw "Found more than one report with the name '$($HaloContactReportBase.name)'. Please delete all but one and try again."
	}

    if ($IncludeReport) {
        $HaloResults = (Get-HaloReport -ReportID $HaloReportBase.id -LoadReport).report.rows
    } else {
        $HaloResults = $HaloReportBase
    }
	
	return $HaloResults
}