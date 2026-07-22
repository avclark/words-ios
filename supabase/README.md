# Supabase setup (Phase 6)

Project: https://wdbouucicnxeoomazerx.supabase.co

## One-time setup, in order

1. **Apply the schema** — Dashboard → SQL Editor → paste `setup.sql` → Run.
   Idempotent; safe to re-run. Creates `profiles`, the signup trigger, and
   the `delete_account` RPC.

2. **Swap the app's API key** — the app currently holds the SECRET key
   (`sb_secret_…`), which must never ship in a client. Dashboard →
   Settings → API Keys → copy the **publishable** key (`sb_publishable_…`)
   into `Words/Words/SupabaseConfig.plist` (gitignored). Then **rotate the
   secret key** (it has been pasted in chat).

3. **Verify the server side** (no Apple needed):
   ```sh
   SUPABASE_SECRET_KEY=sb_secret_... ./verify.sh
   ```
   Exercises: signup trigger → profile row, RLS self-update, the
   `delete_account` RPC, and confirms real deletion.

4. **Once the Apple Developer membership is active** — Dashboard →
   Authentication → Sign In / Providers → Apple → enable, and add the app's
   bundle ID `com.kittyrobotics.Words.Words` to **Authorized Client IDs**.
   (Native iOS flow only needs the bundle ID — no OAuth secret, no redirect
   URL, no Services ID.)

## Identity model (why it satisfies PRODUCT-SPEC)

The stable internal user ID is `auth.users.id`. An Apple login is one row
in `auth.identities` linked to that user — the user HAS an Apple
credential; the user IS NOT the Apple identity. Adding Google or
email/password later inserts another identity row against the same user ID:
purely additive, no migration. `public.profiles` (display name, avatar)
keys off the same ID and is created by trigger on signup.
