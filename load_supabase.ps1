<#
.SYNOPSIS
    One-shot loader: pmt_data.json -> Supabase (no Python required).

.DESCRIPTION
    Reads pmt_data.json from the same folder and posts rows to Supabase's
    REST API in batches. Detects whether `deals` is already loaded and
    skips it if so (idempotent for that case).

.EXAMPLE
    # From the investor-data-room folder, in PowerShell:
    $env:SUPABASE_SERVICE_ROLE_KEY = "eyJhbG...your-key..."
    .\load_supabase.ps1

.NOTES
    The service role key bypasses RLS. Do NOT commit it. Rotate it in
    Supabase dashboard (Settings -> API) after running this script.
#>

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
$SupabaseUrl = 'https://wxfqhrfagwyusxmwlcfz.supabase.co'
$BatchSize   = 500
$JsonPath    = Join-Path $PSScriptRoot 'pmt_data.json'

$ServiceKey = $env:SUPABASE_SERVICE_ROLE_KEY
if (-not $ServiceKey) {
    Write-Host "ERROR: SUPABASE_SERVICE_ROLE_KEY environment variable not set." -ForegroundColor Red
    Write-Host "Get the key from Supabase dashboard -> Settings -> API -> service_role."
    Write-Host 'Then run:  $env:SUPABASE_SERVICE_ROLE_KEY = "eyJ..."'
    exit 1
}

if (-not (Test-Path $JsonPath)) {
    Write-Host "ERROR: $JsonPath not found." -ForegroundColor Red
    Write-Host "Put pmt_data.json next to this script (same folder)."
    exit 1
}

$Headers = @{
    'apikey'        = $ServiceKey
    'Authorization' = "Bearer $ServiceKey"
    'Content-Type'  = 'application/json'
    'Prefer'        = 'return=minimal'
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Clean-Nan {
    # Convert NaN float to $null
    param($value)
    if ($value -is [double] -and [double]::IsNaN($value)) { return $null }
    return $value
}

function Get-RowCount {
    param([string]$Table)
    $countHeaders = $Headers.Clone()
    $countHeaders['Prefer']     = 'count=exact'
    $countHeaders['Range-Unit'] = 'items'
    $countHeaders['Range']      = '0-0'
    try {
        $resp = Invoke-WebRequest -Method Head `
            -Uri "$SupabaseUrl/rest/v1/$Table" `
            -Headers $countHeaders -ErrorAction Stop
        $cr = $resp.Headers['Content-Range']
        if ($cr -is [array]) { $cr = $cr[0] }
        if ($cr -match '/(\d+)$') { return [int]$Matches[1] }
    } catch {
        return -1
    }
    return -1
}

function Invoke-BatchInsert {
    param(
        [string]$Table,
        [System.Collections.IList]$Rows
    )
    if ($Rows.Count -eq 0) {
        Write-Host "  ${Table}: 0 rows, skipping"
        return
    }
    $total = $Rows.Count
    $sent  = 0
    for ($i = 0; $i -lt $total; $i += $BatchSize) {
        $end    = [Math]::Min($i + $BatchSize - 1, $total - 1)
        $chunk  = $Rows[$i..$end]
        $body   = ConvertTo-Json $chunk -Depth 10 -Compress
        try {
            Invoke-RestMethod -Method Post `
                -Uri "$SupabaseUrl/rest/v1/$Table" `
                -Headers $Headers -Body $body | Out-Null
        } catch {
            Write-Host "`n  ERROR on $Table batch starting at $i" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            if ($_.ErrorDetails) { Write-Host "  Details: $($_.ErrorDetails.Message)" -ForegroundColor Red }
            exit 1
        }
        $sent += $chunk.Count
        Write-Host "`r  ${Table}: $sent / $total " -NoNewline
    }
    Write-Host "`r  ${Table}: $sent / $total  OK"
}

# -----------------------------------------------------------------------------
# Read the source JSON
# -----------------------------------------------------------------------------
Write-Host "Reading $JsonPath ..."
$raw  = [System.IO.File]::ReadAllText($JsonPath)
$data = $raw | ConvertFrom-Json

# -----------------------------------------------------------------------------
# Build row arrays
# -----------------------------------------------------------------------------
$deals = New-Object System.Collections.ArrayList
foreach ($r in $data.tape) {
    [void]$deals.Add([ordered]@{
        id              = $r.id
        name            = $r.name
        advance         = Clean-Nan $r.advance
        opb             = Clean-Nan $r.opb
        collected       = Clean-Nan $r.collected
        status          = $r.status
        asset_type      = $r.asset_type
        fin_type        = $r.fin_type
        vintage         = $r.vintage
        charge_off      = $r.charge_off   # date string or null
        close_date      = $r.close_date
        close_type      = $r.close_type
        proj_irr        = Clean-Nan $r.proj_irr
        act_irr         = Clean-Nan $r.act_irr
        total_collected = Clean-Nan $r.total_collected
        moic            = Clean-Nan $r.moic
        term_months     = $r.term_months
        pmts_collected  = $r.pmts_collected
        term_remaining  = $r.term_remaining
    })
}

$dmb = New-Object System.Collections.ArrayList
foreach ($r in $data.tape) {
    foreach ($prop in $r.pit_opb.PSObject.Properties) {
        if ($null -ne $prop.Value) {
            [void]$dmb.Add([ordered]@{
                deal_id = $r.id
                month   = "$($prop.Name)-01"
                opb     = $prop.Value
            })
        }
    }
}

$dpd = New-Object System.Collections.ArrayList
foreach ($prop in $data.dpd.PSObject.Properties) {
    $dealId = [int]$prop.Name
    foreach ($row in $prop.Value) {
        [void]$dpd.Add([ordered]@{
            deal_id       = $dealId
            pmt_num       = $row.pmt_num
            month_str     = $row.month_str
            due_date      = $row.due_date
            sched_amt     = Clean-Nan $row.sched_amt
            actual_amt    = Clean-Nan $row.actual_amt
            dpd_today     = Clean-Nan $row.dpd_today
            resolved_date = $row.resolved_date
            resolved_dpd  = Clean-Nan $row.resolved_dpd
            is_resolved   = $row.is_resolved
            pit_opb       = Clean-Nan $row.pit_opb
        })
    }
}

$sched = New-Object System.Collections.ArrayList
foreach ($prop in $data.sched.PSObject.Properties) {
    $dealId = [int]$prop.Name
    foreach ($row in $prop.Value) {
        [void]$sched.Add([ordered]@{
            deal_id   = $dealId
            pmt_num   = $row.pmt_num
            month_str = $row.month_str
            sched_amt = Clean-Nan $row.sched_amt
        })
    }
}

Write-Host ""
Write-Host "Prepared:"
Write-Host "  deals:                  $($deals.Count) rows"
Write-Host "  deal_monthly_balances:  $($dmb.Count) rows"
Write-Host "  deal_dpd:               $($dpd.Count) rows"
Write-Host "  deal_payment_schedule:  $($sched.Count) rows"
Write-Host "  TOTAL:                  $($deals.Count + $dmb.Count + $dpd.Count + $sched.Count) rows"

# -----------------------------------------------------------------------------
# Pre-check: see if deals is already loaded from an earlier partial run
# -----------------------------------------------------------------------------
$deals_before  = Get-RowCount 'deals'
$dmb_before    = Get-RowCount 'deal_monthly_balances'
$dpd_before    = Get-RowCount 'deal_dpd'
$sched_before  = Get-RowCount 'deal_payment_schedule'

Write-Host ""
Write-Host "Pre-load row counts (from Supabase):"
Write-Host "  deals:                  $deals_before"
Write-Host "  deal_monthly_balances:  $dmb_before"
Write-Host "  deal_dpd:               $dpd_before"
Write-Host "  deal_payment_schedule:  $sched_before"

$loadDeals = $true
if ($deals_before -eq 144) {
    Write-Host ""
    Write-Host "NOTE: 'deals' already has 144 rows (loaded earlier). Skipping deals insert." -ForegroundColor Yellow
    Write-Host "      For a clean reload, first run in Supabase SQL editor:"
    Write-Host "        TRUNCATE public.deals RESTART IDENTITY CASCADE;"
    $loadDeals = $true
}

# -----------------------------------------------------------------------------
# Load
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Loading ..."
# if ($loadDeals) { Invoke-BatchInsert -Table 'deals'                  -Rows $deals }
# Invoke-BatchInsert            -Table 'deal_monthly_balances'  -Rows $dmb
Invoke-BatchInsert            -Table 'deal_dpd'               -Rows $dpd
Invoke-BatchInsert            -Table 'deal_payment_schedule'  -Rows $sched

# -----------------------------------------------------------------------------
# Post-check
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Post-load row counts:"
Write-Host ("  deals:                  {0}  (expected 144)"   -f (Get-RowCount 'deals'))
Write-Host ("  deal_monthly_balances:  {0}  (expected {1})"   -f (Get-RowCount 'deal_monthly_balances'), $dmb.Count)
Write-Host ("  deal_dpd:               {0}  (expected {1})"   -f (Get-RowCount 'deal_dpd'),              $dpd.Count)
Write-Host ("  deal_payment_schedule:  {0}  (expected {1})"   -f (Get-RowCount 'deal_payment_schedule'), $sched.Count)

Write-Host ""
Write-Host "Done." -ForegroundColor Green
