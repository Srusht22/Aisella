# Web test deployment (Vercel)

**Purpose:** a test build of the app in the browser. It is not a production release; the [pre-publication checklist](pre-publication-checklist.md) still applies.

## Why the first deployment showed nothing

- The project had no web target (only `android/` and `ios/`), and no `vercel.json`. Vercel had nothing to build.
- `main` holds only the initial commit. All the app's code is on `S.H_Branch`.
- Even when built, the app needs a backend URL at build time. Without it, it shows a start-up error screen.

## What the repository now has

- `web/`: the Flutter web target.
- `vercel.json`: runs `tool/vercel_build.sh` and serves `build/web`. Every path falls back to `index.html`.
- `tool/vercel_build.sh`:
  - installs Flutter 3.47.7, because Vercel's build image has none;
  - builds with the values below, and serves the Flutter engine files from the site itself rather than Google's CDN;
  - stops with a clear error if the backend values are missing.

## Settings the owner must make in Vercel

1. **Git → Production Branch:** `S.H_Branch`, or merge `S.H_Branch` into `main`. Other branches only get preview deployments.
2. **Settings → Environment Variables:**
   - `SUPABASE_URL`: `https://<project>.supabase.co`;
   - `SUPABASE_PUBLISHABLE_KEY`: the **publishable** (or anon) key.
   - Optional: `ENV_NAME`, which defaults to `staging`.
   - Never use the service-role or a secret key: the app refuses to start with one.
3. **Settings → Deployment Protection:** preview URLs require a Vercel login by default. Turn this off or share the link if testers have no Vercel access.
4. **Redeploy** after changing variables, because they are compiled into the app.

## Backend: needs the owner's approval

The app works only against a **hosted Supabase project** with all migrations in `supabase/migrations/` applied. No hosted project has been set up or migrated: by the standing rules this needs the owner's approval ([project status](project-status.md)). The steps are in the [staging checklist](../architecture/phase-9/k-staging-setup-checklist.md). Also, in Supabase **Authentication → URL Configuration**, add the Vercel URL as the Site URL and a Redirect URL, so that sign-in email links return to the app.

Use a separate test project, with synthetic data only. AI replies and channels stay off.
