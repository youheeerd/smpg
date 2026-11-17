# SMPG

A members-only social game. Members enter a personal invite code, answer ten everyday
moments, write five goals and pick a meeting scene. Everything is saved to a Supabase
database that only the hosts can read.

## What is in this folder

| File | What it is |
| --- | --- |
| `index.html` | The whole game and the host dashboard. No build step. |
| `config.js` | The two values that connect the game to your Supabase project. |
| `supabase/schema.sql` | The database: tables, access rules and functions. |

## Set up (about 15 minutes)

### 1. Create the database

1. Create a free project at [supabase.com](https://supabase.com).
2. Open the **SQL Editor**, paste in all of `supabase/schema.sql`, and run it.
   It is safe to run again later.

### 2. Make yourself a host

1. In Supabase, open **Authentication > Users** and add a user with your email and a
   strong password. Tick the option to confirm the user straight away.
2. Back in the **SQL Editor**, run this with your email:

   ```sql
   insert into public.hosts (user_id)
   select id from auth.users where email = 'you@example.com'
   on conflict do nothing;
   ```

Repeat both steps for anyone else who should see the host dashboard. Every host can
read every member's answers, so add people carefully.

### 3. Connect the game

In Supabase, open the project's **API keys** settings and copy the **Project URL** and
the **publishable** key (older projects call it the `anon` key). Paste both into
`config.js`. Never put a `secret` or `service_role` key in this file.

### 4. Put it online with GitHub Pages

1. In the GitHub repository, open **Settings > Pages**.
2. Under **Build and deployment**, set **Source** to **Deploy from a branch**, then pick
   the `main` branch and the `/ (root)` folder, and save.
3. After a minute or two the site is live at
   `https://<your-github-username>.github.io/<repository-name>/`.

Vercel or any other static host works too, because there is nothing to build.

## Running it

- **Invite a member:** open the site, choose **Host sign-in**, type who the code is for,
  and press **Create code**. Send them the code yourself.
- **Requests to play:** people without a code can send their email, basics and five
  goals. Open the request in the dashboard and choose **Approve and create code**, then
  send them the code. Their request answers are filled in when they enter it.
- **Revoke a code:** press **Revoke** twice. The member is sent back to the door.
- **Spreadsheet of answers:** in the dashboard, **Download answers** saves a CSV file
  with one row per member and every answer, goal, score and trait in its own column.
  **Download requests** does the same for requests to play. Open either in Excel or
  Numbers, or in Google Sheets with **File > Import**. Each download is a snapshot, so
  download again for the latest answers. Supabase's **Table Editor** also shows the
  `plays` table live, with the full record in its `record` column.
- **See answers:** each play in the dashboard opens to the full record: basics, topics,
  relational option, freakquency (or that it was skipped), all ten answers, goals,
  scene, score and trait profile.

## How access is protected

- The website can only call three functions: check a code, save a game for a valid
  code, and send a request. It cannot read or list any table.
- Only signed-in hosts listed in `public.hosts` can read plays, requests and codes, or
  create and revoke codes.
- A member's code is their key. Anyone who has a code can open and overwrite that
  member's game, so treat codes like passwords and send each one privately.

## Known limits

- The site does not send any email. You send codes and introductions yourself.
- Photos added at sign-up stay on the member's device and are not uploaded.
- Anyone can submit a request to play, so expect some junk requests. Each email
  address can only hold one request.
- Matching is still done by you, from the dashboard. Nothing is matched automatically.
