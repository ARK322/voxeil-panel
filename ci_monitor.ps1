# Continuous CI monitor and auto-fix loop
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Owner = "ARK322",
    [string]$Repo = "voxeil-panel",
    [string]$Branch = "main"
)

$headers = @{
    "Accept" = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
if ($Token) {
    $headers["Authorization"] = "Bearer $Token"
}

$iteration = 0
while ($true) {
    $iteration++
    Write-Host "`n========================================"
    Write-Host "CI Monitor - Iteration $iteration - $(Get-Date -Format 'HH:mm:ss')"
    Write-Host "========================================`n"
    
    $commitSha = git rev-parse HEAD
    Write-Host "Monitoring commit: $commitSha"
    
    $runsUrl = "https://api.github.com/repos/$Owner/$Repo/actions/runs?branch=$Branch&per_page=10"
    try {
        $runs = Invoke-RestMethod -Uri $runsUrl -Headers $headers -Method Get
    } catch {
        Write-Host "[ERROR] API request failed: $_"
        Start-Sleep -Seconds 30
        continue
    }
    
    $commitRuns = $runs.workflow_runs | Where-Object { $_.head_sha -eq $commitSha } | Sort-Object -Property created_at -Descending
    
    if ($commitRuns.Count -eq 0) {
        Write-Host "[INFO] No runs found - may be queued"
        Start-Sleep -Seconds 30
        continue
    }
    
    $allPassed = $true
    $inProgress = $false
    
    foreach ($run in $commitRuns) {
        $status = $run.status
        $conclusion = $run.conclusion
        $name = $run.name
        $runId = $run.id
        
        if ($status -eq "in_progress" -or $status -eq "queued") {
            Write-Host "[RUNNING] $name - Status: $status"
            $inProgress = $true
            continue
        }
        
        if ($conclusion -eq "success") {
            Write-Host "[PASS] $name"
        } elseif ($conclusion -eq "failure") {
            Write-Host "[FAIL] $name - https://github.com/$Owner/$Repo/actions/runs/$runId"
            $allPassed = $false
            
            if ($Token) {
                Write-Host "  Fetching job details..."
                $jobsUrl = "https://api.github.com/repos/$Owner/$Repo/actions/runs/$runId/jobs"
                try {
                    $jobs = Invoke-RestMethod -Uri $jobsUrl -Headers $headers -Method Get
                    $failedJob = $jobs.jobs | Where-Object { $_.conclusion -eq "failure" } | Sort-Object -Property started_at | Select-Object -First 1
                    if ($failedJob) {
                        Write-Host "  Failed job: $($failedJob.name)"
                        Write-Host "  Job URL: $($failedJob.html_url)"
                        Write-Host "  Check logs and fix the error, then commit"
                    }
                } catch {
                    Write-Host "  [ERROR] Could not fetch job details: $_"
                }
            }
        } else {
            Write-Host "[$conclusion] $name"
        }
    }
    
    if ($inProgress) {
        Write-Host "`n[WAIT] Workflows still running - checking again in 30s..."
        Start-Sleep -Seconds 30
        continue
    }
    
    if ($allPassed) {
        Write-Host "`n[SUCCESS] All workflows passed!"
        break
    } else {
        Write-Host "`n[ACTION REQUIRED] Fix failures and commit"
        Write-Host "  Waiting 60s for fixes..."
        Start-Sleep -Seconds 60
    }
}

Write-Host "`n[COMPLETE] CI monitoring finished"
