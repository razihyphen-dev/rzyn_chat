# RZYN Chat

A private office chat for GitHub + Netlify + Supabase. The desktop has an OS-inspired home screen; phones use a compact chat layout and can install it as a PWA.

## Features in this source package

- **Chat:** live rooms, replies, seven emoji reactions, `@username` mention suggestions, direct GIPHY/Tenor GIF URLs, stickers, search in the current room, typing indicators, and online presence. Text and link references are stored; GIF files are never uploaded to Supabase.
- **Disappearing content:** ordinary messages expire after 24 hours by default. Anyone with room access can save one permanently (until manually deleted). Admin can change room retention. Vent posts expire after 24 hours; their restricted identity mapping is removed with the post. The cleanup job runs hourly. Search cannot recover expired or deleted messages.
- **Vent:** normal users see posts without author information. An admin can review a specific post while it exists by supplying a reason; the in-app review is logged. The separate signed disclosure must accurately explain this exceptional ability. The app does not call Vent “100% anonymous.”
- **Fun:** 24-hour poll battles, quote nominations and voting for today's top quote (Saudi time), a seven-day Wall of Fame after three distinct colleagues react, XP with a 40-point daily cap and milestone badges, leaderboard, Rock Paper Scissors, Tic Tac Toe, coffee roulette, a wandering/clickable duck, chat `/coin`, `/roll`, and `/8ball question`.
- **Effects:** the covered DO NOT PRESS button triggers a server-enforced cooldown and shared confetti, balloons, disco, lasers, ducks, emoji rain, screen wobble, a countdown, Matrix overlay or a dramatic nothing. Members can reduce or disable effects; admins can broadcast chosen effects.
- **Personalization:** six bundled wallpapers, one compressed image stored locally on each device, optional birthdays, duck toggle, six bundled foreground sounds and custom HTTPS sound pack URLs managed by admins. Admin sets the default; each user may choose a different sound.
- **Accounts:** self registration with name, username, email and password; admin approval required. A unique RZYN member code distinguishes accounts, but it does not identify a device or prove that two accounts belong to the same person.
- **Admin:** approve/reject/pause users, edit names/usernames and roles, rooms and retention, room-by-room read/post permission, announcements, button settings, default wallpaper, feature switches for mascot/push/polls/GIFs/XP, sounds, stickers, moderation, a recent admin activity viewer, and JSON exports of current data. Vent identity mappings are excluded from exports.
- **Push:** the Netlify Function sends Web Push to approved room members with a valid subscription, even if their PWA is closed. Users must explicitly enable it on each device. On iPhone/iPad, install to the Home Screen before enabling push.

**Notification sound boundary:** RZYN can play bundled or admin-added audio while it is open after browser audio is unlocked by user interaction. Closed-app Web Push uses the sound selected by the operating system and browser. A web app cannot reliably attach a chosen custom sound to a lock-screen push on iPhone or Android. Do not promise one to colleagues.

**Free-tier design:** no Supabase media bucket, no video/audio uploads, 24-hour cleanup, bounded message and activity queries, small bundled sounds, short-lived poll/fame data and browser-local effects. Push invokes a Netlify Function once per sent message and sends to enabled devices. Check usage dashboards; zero cost cannot be guaranteed if activity grows or provider plans change.

## Supabase setup (fresh project)

1. Create a Supabase project. Keep **Email** enabled in Authentication. Decide whether to require email confirmation. Later, configure the exact Netlify site URL under **Authentication → URL Configuration**.
2. In the **SQL Editor**, run `supabase/schema.sql` **once**, then run `supabase/02_social_upgrade.sql` **once**, in that order. The scripts are for a fresh installation, not rerunnable migrations. They create RLS rules, the restricted Vent mapping, hourly cleanup, private Realtime channel policies and Push tables. If `pg_cron` is unavailable, enable it under Database → Extensions on a fresh project, then restart setup. Check the Cron job named `rzyn-expiry`.
3. Under **Project Settings → API Keys**, copy the **Project URL**, the **publishable** key (`sb_publishable_…`) and the **secret** key (`sb_secret_…`). Never put the secret key in GitHub, a `VITE_` variable, or browser code.
4. Register your own account first through RZYN, confirm the email if required, then run this in SQL Editor using your exact username:

   ```sql
   update public.profiles
   set role = 'admin', status = 'approved'
   where username = 'YOUR_USERNAME'
   returning id, username, status, role;
   ```

   Check that **one** row is returned. Sign out/back in or use **Check again**.
5. Realtime Broadcast/Presence uses **private** channels. The second SQL script creates their policies. Do not add a broad public policy to `realtime.messages`; that could expose typing or presence.

## GitHub and Netlify

1. Upload the extracted project files to a **private GitHub repository**. Do not upload `.env`, `.env.local`, `node_modules` or any secret. `package-lock.json`, `netlify/functions/`, `public/`, `src/` and both SQL files belong in the repo.
2. Netlify → **Add new site → Import an existing project** → choose that repository. `netlify.toml` sets `npm run build` and `dist`. Set these environment variables in **Netlify's UI**, then deploy:

   | Variable | Value | Scope |
   | --- | --- | --- |
   | `VITE_SUPABASE_URL` | Supabase Project URL | Build |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | Supabase publishable key | Build |
   | `SUPABASE_URL` | Same Project URL | Functions |
   | `SUPABASE_SECRET_KEY` | Supabase **secret** key | Functions only |
   | `VAPID_PUBLIC_KEY` | Generated public key | Functions |
   | `VAPID_PRIVATE_KEY` | Generated **private** key | Functions only |
   | `VAPID_SUBJECT` | `mailto:you@yourdomain.com` | Functions |

3. Generate your VAPID pair locally after `npm install` with `npm run generate:vapid`. Keep both keys stable; replacing them invalidates existing device subscriptions. Never put `VAPID_PRIVATE_KEY` into GitHub or a `VITE_` variable. Netlify Function environment values must be set in the UI, CLI or API; `netlify.toml` does not provide them to Functions.
4. In Netlify **Project configuration → General → Powered by Netlify badge**, turn the badge off and save. The injected badge covers the chat composer on some screen sizes; this setting takes effect without a redeploy.
5. Configure the final Netlify URL in Supabase Authentication. Test registration, admin approval, chat, private room access and two-browser Realtime. The app offers a one-time push invitation after approved sign-in only if its Function reports complete configuration. On iPhone, add the app to the Home Screen and open it there before enabling push. Test a message from another account while the PWA is closed. If push is unavailable, confirm **all five** Function variables above exist in the production environment and have **Functions** scope, then redeploy. The presence of `VAPID_PUBLIC_KEY` alone is insufficient.
6. To lock a room for a group, sign in as an approved app admin, open **Control Room → Permissions**, select **Make private** on that room, then choose **Read + post** (or **Read only**) beside each permitted member. Public rooms are accessible to every approved member until changed. A private room stays invisible to members without a grant; admins can still see it. The starter rooms are public by default.

Local interface work: copy `.env.example` to `.env.local`, fill its two public values, run `npm install && npm run dev`. For the Push Function and full end-to-end tests, use a Netlify deployment or Netlify Dev with Function variables. `npm run build` verifies the production bundle without a Supabase connection.

## Practical limits and safeguards

- One room's content is available only to approved members authorized by RLS. Admin changes to room permissions take effect for database reads immediately; clients already connected to an ephemeral typing channel may need to reconnect for the channel authorization to refresh.
- Closed-app push is best effort: delivery and sound depend on permission, browser, OS and push provider. The app cannot override iPhone lock-screen sound or silent mode.
- Current GIF support accepts **direct GIPHY/Tenor media URLs**; it has no third-party GIF search API or uploaded GIF storage. Remote images and custom pack URLs are fetched from their original hosts.
- Admin JSON exports cover records still present and visible to the admin; they cannot restore expired/deleted data. The in-app audit viewer shows the newest 200 administrative actions. A project owner with direct SQL access operates outside that viewer's logging boundary.
- Saved messages survive normal cleanup, but authors/admins can manually delete them. The seven-day Wall of Fame stores short text snapshots; it is not an indefinite archive.
- The app was **built and source-checked without a connected Supabase or Netlify project**. Database RLS, email delivery, Realtime and device push need the live two-account/device test above before office rollout.
