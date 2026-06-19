$ErrorActionPreference = "Stop"

Write-Output "Git status"
git status --short

Write-Output ""
Write-Output "Git branch"
git branch -vv

Write-Output ""
Write-Output "Docker containers"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"

Write-Output ""
Write-Output "Docker networks"
docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"

Write-Output ""
Write-Output "Docker volumes"
docker volume ls --format "table {{.Name}}\t{{.Driver}}"

Write-Output ""
Write-Output "Protected ports"
$protectedPorts = @(20128, 3264, 9655, 13000, 18000, 15555, 19200, 16379, 15432, 16333, 8080)
foreach ($port in $protectedPorts) {
    $match = netstat -ano | Select-String ":$port\s"
    if ($match) {
        Write-Output "$port occupied"
    } else {
        Write-Output "$port not listening"
    }
}

Write-Output ""
Write-Output "Research status"
python -m json.tool docs/research/status.json | Out-Null
Write-Output "research status json ok"
