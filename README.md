# UKCEH at IC1 — Booth quiz

A six-question quiz for the UKCEH booth at the first International Conference of the Global Framework on Chemicals (IC1, 16–20 November 2026). Delegates scan a QR code (or use the booth iPad), answer, and see how everyone else answered. It follows the UKCEH branding of the [IC1 site](https://github.com/samharrison7/ic1-site).

- **Page:** one static file, `index.html`, with no build step. It is published as the `quiz/` folder of the [IC1 site](https://github.com/samharrison7/ic1-site), at `https://ic1.ceh.ac.uk/quiz/`.
- **Answers:** a free [Supabase](https://supabase.com/) project (hosted Postgres).

## Links

| Use | Address |
|---|---|
| Quiz, for phones (this is what the QR code opens) | `https://ic1.ceh.ac.uk/quiz/` |
| Quiz on the booth iPad | `https://ic1.ceh.ac.uk/quiz/?kiosk` |
| All results on one screen | `https://ic1.ceh.ac.uk/quiz/#display` |
| Results that scroll (what phones see) | `https://ic1.ceh.ac.uk/quiz/#results` |
| Booth team: check prize codes, tune the prize draw | `https://ic1.ceh.ac.uk/quiz/#staff` |
| Layout check with made-up numbers | `https://ic1.ceh.ac.uk/quiz/?demo#display` |
| Preview of the winner screen | `https://ic1.ceh.ac.uk/quiz/?demo&win` |

The quiz is also still up at its original address, `https://samharrison7.github.io/ic1-quiz/`, served straight from this repository. Both addresses use the same database.

Add `theme=light` for a white background, e.g. `?theme=light#display` or `?kiosk&theme=light`.

`?kiosk` makes the quiz suit a shared device: it offers "Start again for the next person", and returns to the start by itself after 20 seconds on the thank-you screen or 60 seconds untouched. Without it, a phone that has answered shows the thank-you screen rather than the quiz, to discourage repeat answers.

## One-off setup

1. **Database:** in the Supabase dashboard, open **SQL Editor**, paste all of `supabase/schema.sql` and run it. It is safe to run again.
2. **Team passphrase:** in the SQL Editor, run the line below with a passphrase of your own (at least 8 characters). It unlocks the `#staff` page. Don't save it in this repository, which is public.
   ```sql
   update public.quiz_settings set staff_passphrase = 'choose something long' where id;
   ```
3. **Key:** the project URL and publishable key are set near the top of the script in `index.html` (`SUPABASE_URL`, `SUPABASE_KEY`). The publishable key is meant to be public. Never put the secret key in this repo.
4. **Hosting:** see "Publishing a change" below.

## Publishing a change

`ic1.ceh.ac.uk/quiz/` is a copy of this repository's `index.html` and `assets/` inside the IC1 site, so a change here only reaches that address when the site is republished. With both repositories checked out side by side:

```bash
cd ../ic1-site
pixi run sync-quiz   # copies the quiz into ic1-site/quiz/
pixi run publish     # rebuilds and publishes the site
```

Commit the updated `quiz/` folder in `ic1-site` too. Pushing this repository's `main` branch updates only the original `samharrison7.github.io/ic1-quiz/` address (GitHub **Settings → Pages → Deploy from a branch → `main` / root**).

## Spot prizes

When someone finishes the quiz, the database decides whether they win. A winner's screen turns green, says "You've won!" and shows a four-character code to bring to the booth.

**At the booth:** open `#staff` on a team phone, enter the passphrase once, and type the winner's code into **Check a winner's code**. It says whether the code is real and marks it as claimed, so a screenshot can't be used twice. The page also lists every prize won so far.

**Tuning the draw:** the same page has the settings. They take effect straight away.

| Setting | Starts at | What it does |
|---|---|---|
| Give out prizes | on | Switch the draw off, for example overnight or when the booth is unstaffed |
| Chance of winning | 1 in 25 | Each person who finishes has this chance |
| Prizes in total | 10 | No more winners once this many have been won |
| Shortest time between winners | 20 minutes | Spreads the prizes out and stops a run of winners |

If prizes are going too fast, raise the "1 in" number or the gap; if too slowly, lower them. A prize that is won but never collected still counts towards the total, so raise the total if you want to give it out again.

Who can win: anyone who answers at least four questions, on a phone or the booth iPad. An answer that was sent late because the device was offline can't win, because that person is no longer looking at the screen.

## Before and during the event

- **Wake the database:** free Supabase projects pause after a week without use. Answer the quiz once a day or two before the event, and check it appears on the display.
- **Clear test answers:** in the SQL Editor, run `truncate public.responses restart identity cascade;` This also clears any prizes the test answers won.
- **Booth iPad:** open the address in Safari, then **Share → Add to Home Screen** to run it full screen. Use **Guided Access** (Settings → Accessibility) to lock the iPad to it. Hold the display iPad in landscape.
- **Switching an iPad between the two jobs:** on the one-screen display, tap the QR code to open the kiosk quiz. On the kiosk quiz, tap the UKCEH logo in the top bar to open the display. Neither is marked on screen; they are for the booth team.
- **Poor wifi:** answers are kept on the device and sent when the connection returns; the results page says how many are waiting. Don't clear the browser's site data while answers are waiting.
- **Download the answers:** Supabase dashboard → **Table Editor → `responses_export` → Export to CSV**. This has one row per person, including any typed "Other" text.

## What visitors can and can't do

The page holds only the publishable key, and `supabase/schema.sql` limits that key to these things:

- **Add an answer sheet.** The database rejects unknown questions or options, more picks than a question allows, and typed text over 80 characters.
- **Learn whether that answer sheet won a prize.** The draw happens in the database, so the page can't be made to award one.
- **Read counts per option.** Individual rows and typed "Other" text are never sent to browsers, so nothing a visitor types can appear on the booth screen.

The `#staff` functions also go through that key, but do nothing without the team passphrase, which is stored only in the database.

No names, emails or IP addresses are stored. Anyone determined could still submit the form many times; the database stops accepting answers at 20,000 rows.

The one-screen display shows only the share of people who got the Jet d'Eau question right, not the answer bars, so it doesn't give the answer away.

## Changing the questions

Edit `QUESTIONS` in `index.html` and `quiz_spec()` in `supabase/schema.sql` together (the option ids must match), then rerun the SQL file. If you add or remove a question, also update `DISPLAY_COLUMNS` in `index.html` and the `responses_export` view.

## Local tooling

Tooling is managed with [Pixi](https://pixi.sh/):

```bash
pixi run serve     # the page at http://localhost:4300 (try /?demo#display)
pixi run test-db   # run schema.sql in a throwaway local Postgres and check its rules
pixi run qr        # regenerate assets/qr.svg (the address is set in tools/make_qr.py)
```
