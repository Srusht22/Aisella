#!/usr/bin/env bash
# Builds the Flutter web app on Vercel. Vercel's build image has no
# Flutter SDK, so this installs the version the project is developed on.
#
# Set these in Vercel → Project → Settings → Environment Variables.
# They are public values; never use a service-role or secret key.
#   SUPABASE_URL              https://<project>.supabase.co
#   SUPABASE_PUBLISHABLE_KEY  sb_publishable_… (or the anon key)
#   ENV_NAME                  optional, defaults to "staging"
set -euo pipefail

FLUTTER_VERSION="3.47.7"

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
  echo "ERROR: SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must be set in the" >&2
  echo "Vercel project's environment variables. Without them the app cannot" >&2
  echo "start. See docs/implementation/web-test-deployment.md." >&2
  exit 1
fi

if [[ ! -x flutter-sdk/bin/flutter ]]; then
  git clone --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git flutter-sdk
fi
export PATH="$PWD/flutter-sdk/bin:$PATH"

flutter config --no-analytics >/dev/null
flutter pub get
flutter build web --release --no-web-resources-cdn \
  --dart-define=ENV_NAME="${ENV_NAME:-staging}" \
  --dart-define=SAMPLE_DATA=false \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY"
