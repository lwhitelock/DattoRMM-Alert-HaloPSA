# DattoRMM-Alerts-Halo
Takes Datto RMM Alert Webhooks and sends them to Halo PSA

### Setup
#### Halo Custom field
Create a custom field on tickets in Halo with these details:
Field Name: DattoAlertType
Field Label: Datto RMM Alert Type
Input Type: Anything
Character Limit: Unlimited

Once created make a note of the ID of the newly created field. It will appear at the end of the URL after id=

#### Halo Custom Reports
Once you have created the custom field we need to create two custom reports in Halo. These will allow quick lookups of Device IDs and existing Alerts from Halo

##### DattoRMMAlerts:
```
SELECT TOP (1000) [Faultid]
      ,[Symptom]
      ,[tstatusdesc]
      ,[dateoccured]
      ,[inventorynumber]
      ,[FGFIAlertType]
      ,[CFDattoAlertType]
  FROM [HaloPSA].[dbo].[FAULTS]
  inner join TSTATUS on Status = Tstatus
  Where CFDattoAlertType is not null
  ```

  ##### DattoRMMDeviceLookup:
  ```
  Select did, DDattoID, DDattoAlternateId from device
  ```

  Make a note of the two report IDs which will be at the end of the URL after id=



### Webhook
```
{
    "alertTroubleshooting": "Please run scandisk and then consult the documentation with the view docs link",
    "docURL": "https://docs.yourdomain.com/alert-specific-kb-article",
    "showDeviceDetails": true,
    "showDeviceStatus": true,
    "showAlertDetails": true,
    "alertUID": "[alert_uid]",
    "alertMessage": "[alert_message]",
	"platform": "[platform]"
}
```