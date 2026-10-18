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
     The name `SUPABASE_ANON_KEY` is also accepted.
   - Tick **Preview** as well as **Production**: deployments of any branch other than the production branch are Preview deployments and only see Preview variables.
   - Optional: `ENV_NAME`, which defaults to `staging`.
   - Never use the service-role or a secret key: the app refuses to start with one.
3. **Settings → Deployment Protection:** preview URLs require a Vercel login by default. Turn this off or share the link if testers have no Vercel access.
4. **Redeploy** after changing variables, because they are compiled into the app.

## Backend: needs the owner's approval

The app works only against a **hosted Supabase project** with all migrations in `supabase/migrations/` applied. No hosted project has been set up or migrated: by the standing rules this needs the owner's approval ([project status](project-status.md)). The steps are in the [staging checklist](../architecture/phase-9/k-staging-setup-checklist.md). Also, in Supabase **Authentication → URL Configuration**, add the Vercel URL as the Site URL and a Redirect URL, so that sign-in email links return to the app.

Use a separate test project, with synthetic data only. AI replies and channels stay off.

## When sign-up says "Something went wrong"

Test builds (anything but `ENV_NAME=prod`) add the provider's error code to auth error messages, for example "Something went wrong. Please try again. (unexpected_failure)". Production never shows it. Common codes on a new Supabase project:

| Code | Cause | Fix |
|---|---|---|
| `email_address_not_authorized` | Supabase's built-in email service only sends to members of the project's team | Use a team member's email for testing, add custom SMTP (Authentication → Emails → SMTP), or turn off **Confirm email** (Authentication → Sign In / Providers → Email) for the test project only |
| `over_email_send_rate_limit` / `429` | The built-in email service sends only a few emails per hour | Wait an hour, use custom SMTP, or turn off **Confirm email** for testing |
| `unexpected_failure` / `500` | Usually the confirmation email failed to send | Same as above |
| `invalid API key` / `401` | Wrong key in Vercel | Use the publishable (anon) key, then redeploy |

On the web, email links return to the site itself, so the site's address must be the **Site URL** and be listed under **Redirect URLs** (Authentication → URL Configuration).

Store setup and every screen after sign-in also need the database migrations applied to the project (see above). Without them, sign-up can succeed but the next step fails.
