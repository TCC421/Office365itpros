# SketchPad.PS1
# Used for bits of PowerShell I am working on or want to note

# Get list to update metadata for the new item
$ListId = (Get-MgSiteList -SiteId $Site.Id -Filter "DisplayName eq 'Documents'").Id
[array]$ListItems = Get-MgSiteListItem -SiteId $Site.Id -ListId $ListId
$ListItem = $ListItems[-1]
$Body = @{}
$Body.Add("Title", "Hard Deleted Users Report Created by Azure Automation")
$Status = Update-MgSiteListItemField -SiteId $site.Id -ListId $listId -ListItemId $listItem.Id -BodyParameter $Body
If ($Status) {
    Write-Output ("Updated document metadata for item {0} with title {1}" -f $ListItem.Id, $Params.Title)
}




# Report all OneDrive accounts
[array]$Users = Get-MgUser -Filter "assignedLicenses/`$count ne 0 and userType eq 'Member'" `
    -ConsistencyLevel eventual -CountVariable UsersFound -All -PageSize 500
If (!$Users) {
    Write-Host "No user accounts found"
    Break
}
$Report = [System.Collections.Generic.List[Object]]::new()
ForEach ($User in $Users) {
    Try {
        $OneDrive = Get-MgUserDefaultDrive -UserId $User.Id -ErrorAction Stop
    } Catch {
        Write-Host ("Unable to find OneDrive for {0}" -f $User.UserPrincipalName)
        Continue
    }   
    $ReportLine = [PSCustomObject][Ordered]@{
        UserPrincipalName = $User.UserPrincipalName
        OneDriveUrl       = $OneDrive.WebUrl
        Created           = Get-Date $OneDrive.CreatedDateTime -format 'dd-MMM-yyyy HH:mm'
        Modified          = Get-Date $OneDrive.LastModifiedDateTime -format 'dd-MMM-yyyy HH:mm'
    }
    $Report.Add($ReportLine)
}

# --- Add multiple members from a Microsoft 365 Group to another group

$SourceGroup = Get-MgGroup -Filter "DisplayName eq 'Bala Group'"
$TargetGroup = Get-MgGroup -Filter "DisplayName eq 'Bedson Project'"
[array]$MembersSourceGroup = Get-MgGroupMember -GroupId $SourceGroup.Id -All | Select-Object -ExpandProperty Id
[array]$MembersTargetGroup = Get-MgGroupMember -GroupId $TargetGroup.Id -All | Select-Object -ExpandProperty Id
# Remove source members who are already members of the target group
$MembersSourceGroup = $MembersSourceGroup | Where-Object { $MembersTargetGroup -notcontains $_ }
$Data = [System.Collections.Generic.List[Object]]::new()
$MembersSourceGroup | ForEach-Object {$Data.Add("https://graph.microsoft.com/beta/directoryobjects/{0}" -f $_)}
While ($Data.count -ne 0) {
    $Parameters = @{"members@odata.bind" = $Data[0..19] }
    Update-MgGroup -GroupId $TargetGroup.Id -BodyParameter $Parameters
    If ($Data.count -gt 20) {
        $Data.RemoveRange(0.20)
    } Else {
        $Data.RemoveRange(0,$Data.count)
    }
}

$SelectedUsers = Get-MgUser -Filter "userType eq 'Member'"
$MsgFrom = 'Customer.Services@office365itpros.com'
# Define some variables used to construct the HTML content in the message body
# HTML header with styles
$HtmlHead="<html>
    <style>
    BODY{font-family: Arial; font-size: 10pt;}
	H1{font-size: 22px;}
	H2{font-size: 18px; padding-top: 10px;}
	H3{font-size: 16px; padding-top: 8px;}
    H4{font-size: 8px; padding-top: 4px;}
</style>"

$HtmlBody = $null
$HtmlBody = $HtmlBody + "<body> <h1>Users</h1><p></p>"   

$HtmlBody = $HtmlBody + ($SelectedUsers| Sort-Object DisplayName | ConvertTo-HTML -Fragment -As Table -PreContent "<h2>Administrative alert: Inactive Teams based on 30-day lookback</h2>")
$HtmlBody = $HtmlBody + "<p>These users are member accounts</p>"
$HtmlBody = $HtmlBody + "<p><h4>Generated:</strong> $(Get-Date -Format 'dd-MMM-yyyy HH:mm')</h4></p>"

$HtmlMsg = $HtmlHead + $HtmlBody + "<p></body>"

$MsgSubject = "Member users"

$ToRecipients = @{}
$ToRecipients.Add("emailAddress", @{"address"="tony.redmond@office365itpros.com"} )
[array]$MsgTo = $ToRecipients

# Construct the message body
$MsgBody = @{}
$MsgBody.Add('Content', "$($HtmlMsg)")
$MsgBody.Add('ContentType','html')

$Message = @{}
$Message.Add('subject', $MsgSubject)
$Message.Add('toRecipients', $MsgTo)    
$Message.Add('body', $MsgBody)

$Params = @{}
$Params.Add('message', $Message)
$Params.Add('saveToSentItems', $true)
$Params.Add('isDeliveryReceiptRequested', $true)    

Send-MgUserMail -UserId $MsgFrom -BodyParameter $Params


#-----------

[array]$ProductData = Invoke-RestMethod -Method Get -Uri "https://download.microsoft.com/download/e/3/e/e3e9faf2-f28b-490a-9ada-c6089a1fc5b0/Product%20names%20and%20service%20plan%20identifiers%20for%20licensing.csv" | ConvertFrom-CSV
If ($ProductData) {
    [array]$ProductInfo = $ProductData | Sort-Object GUID -Unique
    $ProductInfoHash = @{}
    ForEach ($P in $ProductInfo) {
        $ProductInfoHash.Add([string]$P.GUID, [string]$P.Product_Display_Name)
    }   
} Else {
    Write-Host "Unable to retrieve product data"
    Break
}

[array]$TenantSkus = Get-MgSubscribedSku -All | Select-Object SkuId, SkuPartNumber, ServicePlans, ConsumedUnits, PrepaidUnits

# Get all groups with assigned licenses
Write-Host "Finding groups used by group-based licensing..."
[array]$Groups = Get-MgGroup -All -Filter "assignedLicenses/`$count ne 0" `
    -ConsistencyLevel Eventual -CountVariable Count -Property Id, DisplayName, AssignedLicenses

If (!$Groups) {
    Write-Host "No groups found with assigned licenses"
    Break
} Else {
    Write-Host ("Found {0} groups with assigned licenses" -f $Groups.Count)
}

$Report = [System.Collections.Generic.List[Object]]::new()
$GroupBasedSkusReport = [System.Collections.Generic.List[Object]]::new()

Write-Host "Analyzing group-based licensing..."
ForEach ($Group in $Groups) {
    # Resolve product identifiers to product names for each license
    $ProductNames = @()
    ForEach ($License in $Group.AssignedLicenses) {
        $ConsumedUnits = 0; $PrepaidUnits = 0
        $ProductNames += $ProductInfoHash[$License.SkuId]
        $ConsumedUnits = ($TenantSkus | Where-Object {$_.SkuId -eq $License.SkuId}).ConsumedUnits
        $PrepaidUnits = ($TenantSkus | Where-Object {$_.SkuId -eq $License.SkuId}).PrepaidUnits.Enabled
        $GroupBasedSkuLine = [PSCustomObject][Ordered]@{
            SkuId           = $License.SkuId
            'Product name'  = $ProductInfoHash[$License.SkuId]
            ConsumedUnits   = $ConsumedUnits
            PrepaidUnits    = $PrepaidUnits
            AvailableUnits  = $PrepaidUnits - $ConsumedUnits
            'GroupId'       = $Group.Id
        }
        $GroupBasedSkusReport.Add($GroupBasedSkuLine)
    }
    [array]$GroupMembers = Get-MgGroupMember -GroupId $Group.Id -All 
    $ReportLine = [PSCustomObject][Ordered]@{
        DisplayName         = $Group.DisplayName
        GroupId             = $Group.Id
        Licenses            = $ProductNames -join ', '
        Members             = $GroupMembers.Count
        'Member names'      = ($GroupMembers.additionalProperties.displayName -join ', ')
        AssignedLicenses    = $Group.AssignedLicenses
    }
    $Report.Add($ReportLine)
}

$HtmlHead="<html>
    <style>
    BODY{font-family: Arial; font-size: 10pt;}
	H1{font-size: 22px;}
	H2{font-size: 18px; padding-top: 10px;}
	H3{font-size: 16px; padding-top: 8px;}
    H4{font-size: 8px; padding-top: 4px;}
</style>"
$HtmlBody = $HtmlHead
ForEach ($Sku in $GroupBasedSkusReport) {
    $GroupData = $Report | Where-Object {$_.GroupId -eq $Sku.GroupId}
    $HtmlHeader = ("<h2>Product: {0}" -f $Sku.'Product name') + "</h2><p>"
    $HtmlHeader = $HtmlHeader + ("<p><h2>Licenses assigned through group {0}</h2>" -f $GroupData.DisplayName) + "</p>"
    $HtmlHeader = $HtmlHeader + ("<p><h3>Consumed units: {0} Prepaid Units: {1} Available Units: {2} Assigned through group: {3}</h3> " `
        -f $Sku.ConsumedUnits, $Sku.PrepaidUnits, $Sku.AvailableUnits, $GroupData.Members) + "</p>"
    If ($Sku.AvailableUnits -le 0) {
        $HtmlHeader = $HtmlHeader + "<p><strong>Warning: No more licenses availble</strong></p>"
    } ElseIf ($Sku.AvailableUnits -lt 10) {
        $HtmlHeader = $HtmlHeader + "<p><strong>Warning: Less than 10 licenses available</strong></p>"
    }
    $HtmlBody = $HtmlBody + $HtmlHeader + ("<p>Licenses assigned to the following members: {0}" -f $GroupData.'Member names') + "</p>"
}
$HtmlMsg = $HtmlBody + "<p><h4>Generated:</strong> $(Get-Date -Format 'dd-MMM-yyyy HH:mm')</h4></p>""<p></body>"

$MsgSubject = "Group-based licensing report"
$MsgFrom = (Get-MgContext).Account
$ToRecipients = @{}
$ToRecipients.Add("emailAddress", @{"address"="tony.redmond@office365itpros.com"} )
[array]$MsgTo = $ToRecipients

# Construct the message body
$MsgBody = @{}
$MsgBody.Add('Content', "$($HtmlMsg)")
$MsgBody.Add('ContentType','html')

$Message = @{}
$Message.Add('subject', $MsgSubject)
$Message.Add('toRecipients', $MsgTo)    
$Message.Add('body', $MsgBody)

$Params = @{}
$Params.Add('message', $Message)
$Params.Add('saveToSentItems', $true)
$Params.Add('isDeliveryReceiptRequested', $true)    

Send-MgUserMail -UserId $MsgFrom -BodyParameter $Params
