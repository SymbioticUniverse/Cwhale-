param([int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$page = Join-Path (Split-Path -Parent $PSScriptRoot) 'admin_workbench/index.html'
if (-not (Test-Path -LiteralPath $page)) { throw "工作台页面不存在：$page" }
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Cwhale 本地工作台：http://127.0.0.1:$Port/ （按 Ctrl+C 关闭）"
try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $response = $context.Response
    if ($context.Request.HttpMethod -ne 'GET' -or $context.Request.Url.AbsolutePath -notin @('/', '/index.html')) {
      $response.StatusCode = 404
      $response.Close()
      continue
    }
    $bytes = [System.IO.File]::ReadAllBytes($page)
    $response.ContentType = 'text/html; charset=utf-8'
    $response.Headers['Cache-Control'] = 'no-store'
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.Close()
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
