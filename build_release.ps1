$dateDay  = Get-Date -Format "yyyyMMdd"
$dateTime = Get-Date -Format "HHmm"
$apkDate  = Get-Date -Format "yyyyMMdd_HHmm"

# 3 νούμερα πριν το +, όλο το timestamp μετά
$version  = "1.0.0"
$code     = "$dateDay$dateTime"

# ─────────────────────────────────────────────────────────────
# API KEYS (μέσω --dart-define ώστε να ΜΗΝ μπαίνουν στον κώδικα).
# Βάλε εδώ τα ΠΡΑΓΜΑΤΙΚΑ restricted κλειδιά σου.
#   • ANDROID_MAPS_KEY: Android-restricted (package+SHA) με Places(New)+Routes+Geocoding
#   • WEB_MAPS_KEY    : referrer-restricted (για web builds — προαιρετικό εδώ)
# Αν αφήσεις κενό, χρησιμοποιείται το fallback από τον κώδικα.
# ─────────────────────────────────────────────────────────────
$ANDROID_MAPS_KEY = "AIzaSyBDPK5fO8Uo2XGvfaPM8kkPhXoeJi1-6Co"

$pubspec = Get-Content "pubspec.yaml" -Raw
$pubspec = $pubspec -replace 'version: .*', "version: $version+$code"
Set-Content "pubspec.yaml" $pubspec -NoNewline

Write-Host "Building v$version+$code..." -ForegroundColor Cyan

flutter build apk --release --dart-define=ANDROID_MAPS_KEY=$ANDROID_MAPS_KEY

$src = "build\app\outputs\flutter-apk\app-release.apk"
$dst = "build\app\outputs\flutter-apk\AthensTaxi_v$apkDate.apk"

if (Test-Path $src) {
    Copy-Item $src $dst -Force
    Write-Host "Done: AthensTaxi_v$apkDate.apk" -ForegroundColor Green
} else {
    Write-Host "Build failed." -ForegroundColor Red
}
