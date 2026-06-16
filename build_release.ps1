$dateDay  = Get-Date -Format "yyyyMMdd"
$dateTime = Get-Date -Format "HHmm"
$apkDate  = Get-Date -Format "yyyyMMdd_HHmm"

# Εδώ είναι η διόρθωση: 3 νούμερα πριν το +, όλο το timestamp μετά
$version  = "1.0.0"
$code     = "$dateDay$dateTime"

$pubspec = Get-Content "pubspec.yaml" -Raw
$pubspec = $pubspec -replace 'version: .*', "version: $version+$code"
Set-Content "pubspec.yaml" $pubspec -NoNewline

Write-Host "Building v$version+$code..." -ForegroundColor Cyan

flutter build apk --release

$src = "build\app\outputs\flutter-apk\app-release.apk"
$dst = "build\app\outputs\flutter-apk\AthensTaxi_v$apkDate.apk"

if (Test-Path $src) {
    Copy-Item $src $dst -Force
    Write-Host "Done: AthensTaxi_v$apkDate.apk" -ForegroundColor Green
} else {
    Write-Host "Build failed." -ForegroundColor Red
}