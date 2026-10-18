#!/usr/bin/env bash
# Builds the Flutter web app on Vercel. Vercel's build image has no
# Flutter SDK, so this installs the version the project is developed on.
#
# Set these in Vercel → Project → Settings → Environment Variables.
# They are public values; never use a service-role or secret key.
#   SUPABASE_URL              https://<project>.supabase.co
#   SUPABASE_PUBLISHABLE_KEY  sb_publishable_… (or the anon key; the name
#                             SUPABASE_ANON_KEY is also accepted)
#   ENV_NAME                  optional, defaults to "staging"
set -euo pipefail

FLUTTER_VERSION="3.47.7"

# Older docs called the publishable key SUPABASE_ANON_KEY; accept either.
SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY:-${SUPABASE_ANON_KEY:-}}"

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
  echo "ERROR: SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY (or SUPABASE_ANON_KEY)" >&2
  echo "must be set in the Vercel project's environment variables, for the" >&2
  echo "environment being built (VERCEL_ENV=${VERCEL_ENV:-unknown}). Without them" >&2
  echo "the app cannot start. See docs/implementation/web-test-deployment.md." >&2
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
