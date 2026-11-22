# Cycle estimates: audit of the math, markers and science

2026-11-22. A read-only review of the cycle-tracking estimates (MVCALE-28, MVCALE-52), checked against published research and against how other cycle apps behave. No code was changed. The edge cases below were run on a copy of `Cycle.swift` outside the repo.

Where the code is:

- `Sources/CalendarKit/Cycle.swift`: `CalCycleEstimator` works out periods, lengths, predictions, the fertile window and the cycle day.
- `Sources/CalendarKit/PrivateViews.swift`: the grid bands (`CycleBand`), the drops (`DropMark`), which mark wins a day (`PrivateMarks.rank`), the day detail and the legend.
- The server (mvCalendar) only stores the days and settings, encrypted; it does no estimating. See "Backend" at the end.

## Summary

| # | Finding | Kind | Priority |
|---|---------|------|----------|
| 1 | A long mid-cycle bleed makes a fake start and hides the real next one | Bug | High |
| 2 | A late period isn't handled: wrong cycle day, a fertile window while late, expected bands left in the past | Bug | High |
| 3 | A month left unlogged (a gap of about 56 days) is averaged in as one cycle | Bug | Medium |
| 4 | Ovulation is placed at next start − 14; the data says 12–13 | Science | Medium |
| 5 | The fertile window is a fixed 6 days, however irregular the cycles are | Science | Medium |
| 6 | The days between the period and the fertile window are unmarked, which reads as "safe" | Markers / science | Medium |
| 7 | The code comment credits ACOG with "average − 14" | Wording | Low |
| 8 | In short cycles the period mark hides most of the fertile window | Markers | Low |
| 9 | The mean, not the median, of recent cycles | Science | Low |

What's already right is listed further down.

## Current rules (as built)

- **Periods** (`periods`, Cycle.swift:158):
  - A period begins at a "Period started" mark, or at a bleeding day. Spotting never begins one.
  - A bleeding day less than 15 days after the last period's start is mid-cycle bleeding, not a new period.
  - Bleeding days at most 3 days apart continue the same period.
  - A "Period ended" mark within 15 days of the start ends the period.
  - A period begun with a mark stays open until it's ended. One made only of logged bleeding days ends at its last bleeding day.
- **Cycle length**: the rounded mean of the last 6 gaps between starts. Gaps outside 15–60 days are ignored. Otherwise the person's setting, otherwise 28.
- **Period length**: the rounded mean of the last 6 finished periods (1–12 days each). Otherwise the setting, otherwise 5.
- **Predictions**: last start + cycle length × k, for k = 1 to 3.
- **Ovulation**: next start − 14 days. **Fertile window**: the 5 days before ovulation plus ovulation day.
- **Cycle day**: counted from the latest start on or before the day, whether logged or predicted.

## Bugs

### 1. A long mid-cycle bleed makes a fake start (Cycle.swift:166-186)

The "under 15 days since the last start" rule checks each bleeding day on its own. So in a run of mid-cycle bleeding, the first day that reaches 15 days after the start counts as a new period. That fake start then hides the real period that follows, and a day in the middle of the real period becomes the next start.

The run:

```
Period 9-1 (4 days), light bleeding 9-12..9-17 (6 days), period 9-29 (4 days)
  starts:       2026-09-01, 2026-09-16, 2026-10-01     (should be 09-01, 09-29)
  cycle length: 15                                     (should be 28)

Period 3-1 (5 days), bleeding 3-17..3-18, period 3-29 (5 days)
  starts:       2026-03-01, 2026-03-17, 2026-04-01     (should be 03-01, 03-29)
  cycle length: 16
```

The existing test (`aMidCycleBleedIsNeitherAStartNorPartOfThePeriod`) uses a single mid-cycle day, so it passes.

**Fix:** treat a run of bleeding that is skipped as mid-cycle as one block, using the same "3 days apart" rule as a period. No day inside that block can start a period. The next period can begin only after the block. Add tests for a 6-day bleed that crosses day 15, and for a bleed on day 17 followed by a real period 12 days later.

### 2. Late periods aren't handled (Cycle.swift:217-262)

Predictions come from the last logged start and ignore today. Once the predicted date has passed with nothing logged:

```
28-day cycles, last start 10-27, predicted 11-24, today 12-05, nothing logged
  cycle day on 12-05:     12        (really 40: it restarted at the predicted 11-24)
  11-24..11-27:           "period expected", now in the past
  12-03..12-08:           a fertile window and ovulation shown for a cycle that hasn't begun
```

The fertile window during a late period is the worst part, because a late period can mean pregnancy.

How the other apps handle it:

- Clue shows "Your period is X days late".
- Flo predicts a window of days the period may arrive in. Once that window closes, it shows a delay notice and hides future period and ovulation predictions until a period is logged.

**Fix:** pass `today` into the prediction. When today is past the next predicted start and no period has been logged since:

- count the cycle day from the last *logged* start;
- give the day detail a "late by N days" state;
- don't predict later periods or fertile windows until a period is logged.

Past expected-period bands can stay up to today, since "expected, didn't come" is useful, but nothing beyond today. The grid already passes `today` (`PrivateIndex.marks`), so the views need no change.

### 3. A month left unlogged is averaged in (Cycle.swift:198)

The 15–60 filter accepts a gap of twice the usual length:

```
gaps 28, 28, 56 (one period not logged) → cycle length 37, next start predicted ~9 days late
```

**Fix:** drop any gap far from the person's own median, for example over 1.6× or under 0.6× of it, keeping 15–60 as the outer limit. Once there are 3 or more gaps, also use the median in place of the mean (finding 9). Clue lets people hide an unusual cycle from the averages by hand; see "Backend" for what that would need.

## Science

### 4. Ovulation at next start − 14 is about 1–2 days early (Cycle.swift:247)

The time from ovulation to the next period (the luteal phase) is treated as a fixed 14 days. Large datasets put it at 12–13 days:

- **Bull et al. 2019**, *npj Digital Medicine* 2:83 (612,613 cycles from Natural Cycles): the luteal phase averaged **12.4 days** (SD 2.4, range 7–17), and 12.6 days even in 28-day cycles. 18% were under 11 days. The follicular phase (period start to ovulation) averaged 16.9 days (SD 5.3), and it accounts for most of the variation in cycle length. Each person's cycle length varied by a mean SD of 2.6 days. The paper calls the "ovulation on day 14" idea "not correct" for most women. Funded by Natural Cycles.
- **Fehring, Schneider & Raviele 2006**, *JOGNN* 35:376 (1,060 cycles): mean cycle 28.9 days. Phase means of a 12.4-day luteal phase and a 16.5-day follicular phase are cited elsewhere; I couldn't confirm them in the original. 42.5% of women had cycles varying by more than 7 days.
- **Lenton et al. 1984**, *BJOG* 91:685 (from the LH peak): about 14.1 ± 1.4 days. This is where 14 comes from. Only a secondary record gives this figure.
- **Apple Cycle Tracking** uses 13 days (Apple's instructions for use, v4).

**Fix:** use 13 (as Apple does) or 12, and update the tests that pin 14 (`whatEachDayIs`, `markedPeriodsFillAndSetTheLength`). On its own this moves the teal one day later, which widens the unmarked stretch before it. That's why it should ship with finding 6.

### 5. The window doesn't widen for irregular cycles

The 6 days ending on ovulation day are right. Ovulation moving from cycle to cycle is the bigger problem:

- **Wilcox, Weinberg & Baird 1995**, *NEJM* 333:1517: every pregnancy followed sex in the 6 days ending on ovulation day. The chance per day rose from about 0.10 five days before ovulation to 0.33 on ovulation day.
- **Wilcox, Dunson & Baird 2000**, *BMJ* 321:1259: only about **30%** of women had their whole fertile window inside days 10–17. On every day from cycle day 6 to day 21, at least 10% of women were in their window. Even women with regular cycles had a 1–6% chance of being fertile on the day their period was due.
- **Johnson et al. 2018**, *Current Medical Research and Opinion* 34(9):1587 (949 women): in 28-day cycles the most common ovulation day was day 16 (21%); day 14 was 14%. Apps predicted the ovulation day no better than 21% of the time. The authors work for SPD (Clearblue).
- **Setton et al. 2016**, *Obstetrics & Gynecology* 127 suppl.: only 3 of 33 apps predicted the exact fertile window, and the windows shown ranged from 4 to 12 days.

The run:

```
gaps 24, 35, 26, 33, 25, 34 → cycle length 30
  shown:              days 12–17 (6 days)
  calendar method:    days 6–24 (shortest − 18 to longest − 11)
```

**Fix:** see finding 6. The faint band is this widening.

### 6. The unmarked days before the window read as "safe"

With a period on 11-14 to 11-18 and the window on 11-26 to 12-01, the days 11-19 to 11-25 (cycle days 6–12) are blank, so it looks like a safe stretch. It isn't:

- In Wilcox 2000, at least 10% of women were fertile on each day from day 6.
- Sperm can survive up to 5 days, so sex on day 9 can lead to pregnancy if ovulation comes early, around day 13–14.
- The Standard Days Method treats days 8–19 as fertile for cycles of 26–32 days.

The days after the window and before the next period are the lowest-risk part of the cycle, because the time after ovulation is fairly steady. Even those aren't certain on dates alone, because ovulation can come late.

**Proposal: two levels of teal, both from the person's own cycles.**

| Shading | Days | Meaning |
|---|---|---|
| Teal (as now) | estimated ovulation − 5 through ovulation | Most likely fertile |
| Very faint teal (new) | shortest recent cycle − 18 through longest − 11 (the calendar method). With fewer than 3 logged cycles: days 8–19 (Standard Days Method). Always at least as wide as the teal. | Fertility possible |
| None | the rest | Lower chance, not zero |

How it behaves:

- With regular cycles the faint band shrinks to a day or two either side of the teal.
- With irregular cycles it grows.
- It always covers from about day 8, so the blank stretch after the period goes away.

Details:

- **Model:** a new kind, for example `CalCycleDayInfo.Kind.fertilePossible`.
  - It ranks below `.fertile` in `PrivateMarks.rank`, so it never hides a stronger mark from the other partner's cycle.
  - It ranks below `.predictedPeriod` too.
- **Look:** about half the opacity of the current light teal (about 0.07–0.08), with no dashed edges (the dashes mean "expected period").
- **Words:**
  - Shaded days: "Fertility possible · estimate", in the day detail, the legend and VoiceOver.
  - Unshaded days: "Lower chance, not zero · estimate" in the day detail rather than nothing.
  - Never use the word "safe" anywhere.
- **When late:** the band hides with the other fertility marks while a period is late (finding 2).
- **What it replaces:** this is the widening from finding 5, so one change covers both.

How other apps handle it:

- Apple and Clue mark only the window. Their help text says no day outside it is guaranteed safe.
- Clue's window is 7 days: the days up to ovulation, ovulation day, and the day after.
- Natural Cycles goes the other way and marks every day it hasn't confirmed as fertile (red). It's a temperature-based contraceptive, not a calendar estimate.

### 7. "The calendar method (ACOG)" (Cycle.swift:132)

The ACOG-linked material describes the Standard Days Method (days 8–19 for cycles of 26–32 days) and calendar rhythm: record 6–12 cycles, then shortest − 18 to longest − 11 (Mayo Clinic, citing ACOG; the MSD Manual uses shortest − 19). None of it describes "average − 14". ACOG's own FAQ page blocked automated reading, so this is likely rather than confirmed.

**Fix:** call it "a calendar estimate (cycle-length based)" in the comment.

### 8. Short cycles hide the window (PrivateViews.swift:55-62)

```
22-day cycles, 7-day periods: window = cycle days 4–9; the period mark wins days 4–7
  shown:  PPPPPPPfO   (only days 8–9 of the window are visible)
```

Being fertile during a period is real in short cycles. A band can show only one color, so keeping the period on top is reasonable. The day detail could still add "fertile window" on those days.

### 9. Mean vs median, and how many cycles

- Li et al. 2020, *npj Digital Medicine* 3:79 (Clue, 4.9 million cycles): mean 29.73 days, median 29. A difference of 9+ days between one cycle and the next separates people whose cycles vary a lot.
- Clue uses the last 12 cycles for predictions and the last 6 for averages.
- Apple waits for 2 logged periods before predicting. Flo starts after 1, as this app does.

Moving to the median of the last 6 (once there are 3 or more) is a cheap way to make outliers matter less.

## Normal ranges (for limits and settings)

- **FIGO 2018** (Munro, Critchley & Fraser, *Int J Gynaecol Obstet* 143:393):
  - a period every 24–38 days, bleeding 8 days or less;
  - a shortest-to-longest spread of about 7–9 days or less (confirmed only through secondary sources).
- **ACOG Committee Opinion 651** (2015, adolescents): 21–45 days.
- **Apple:** "irregular" means a shortest-to-longest spread of 17+ days over 6 months.
- **Flo:** stops predicting when the predicted cycle is under 20 or over 60 days.
- **Bull 2019:** real ovulatory cycles of 15–20 days exist, so 15 is a defensible lower limit for accepting a gap.

The settings limits (cycle 20–45, period 1–10) and the measured period limit (1–12) fit these.

## What's already right

- The fertile window is 6 days ending on ovulation day (Wilcox 1995).
- Spotting never starts a period or counts toward its length (as in Clue and Apple).
- Averages use the last 6 cycles (as in Clue).
- Logged lengths win over settings, and settings win over the defaults.
- Predictions start after one logged period (as in Flo).
- The colors follow the usual convention: pink for periods, teal for the fertile window, and a lighter or dashed look for expected days. Clue, Flo and Natural Cycles look similar (see mvCalendar `docs/research/intimacy/leaf-apps.md`).
- The disclaimer "Estimates only. Not a medical device or birth control." matches the evidence on calendar-only apps (Setton 2016, Johnson 2018).

## Suggested order of work

1. Bug 1 (the mid-cycle block) and bug 2 (late period), each with tests that fail on the current code.
2. The faint band and the widening (5 + 6), shipped with the move from −14 to −13 (4), plus the legend and the wording.
3. Rejecting outlier gaps and using the median (3 + 9).
4. Reword the comment (7). Add the window to the day detail on short cycles (8).

## Backend (mvCalendar)

**Nothing needs to change for any of the above.** The server stores each logged day (date, flow, start and end marks) and each person's settings, encrypted, and does no estimating (`internal/store/cycle.go`; migration 006 notes "Estimates ... are the phone's"). Its checks, cycle 20–45 and period 1–10 in `internal/rpc/intimate.go:420-425`, fit FIGO and ACOG.

It would only need to change for later features that store new data:

- **Hiding an unusual cycle from the averages** (as Clue does): a flag on a cycle day, or a list of excluded starts in the settings. That means a proto field, passing it through in `SaveCycleDay` or `SaveCycleSettings` (the server builds the stored record from the request's fields, so a new field needs handling there), and a check.
- **Logging LH (ovulation) tests**, which Apple uses to move the window: a new field or row type in the cycle stream.
- **A personal luteal-length setting:** a field on `CycleSettings`, with a check (about 10–16 days).

## Sources

- Bull JR et al. 2019, *npj Digital Medicine* 2:83. https://pmc.ncbi.nlm.nih.gov/articles/PMC6710244
- Lenton EA, Landgren BM, Sexton L 1984, *BJOG* 91:685–9. https://pubmed.ncbi.nlm.nih.gov/6743610/
- Fehring RJ, Schneider M, Raviele K 2006, *JOGNN* 35:376. https://epublications.marquette.edu/nursing_fac/11
- Wilcox AJ, Weinberg CR, Baird DD 1995, *NEJM* 333:1517.
- Wilcox AJ, Dunson D, Baird DD 2000, *BMJ* 321:1259. https://pmc.ncbi.nlm.nih.gov/articles/PMC27529
- Li K et al. 2020, *npj Digital Medicine* 3:79. https://pmc.ncbi.nlm.nih.gov/articles/PMC7250828
- Johnson S, Marriott L, Zinaman M 2018, *Curr Med Res Opin* 34(9):1587. https://www.tandfonline.com/doi/10.1080/03007995.2018.1475348
- Setton R et al. 2016, *Obstet Gynecol* 127 suppl. (summary: https://medicalxpress.com/news/2016-06-websites-apps-accurate-fertile-window.html)
- Munro MG, Critchley HOD, Fraser IS 2018 (FIGO), *Int J Gynaecol Obstet* 143:393. Table: https://www.merckmanuals.com/professional/multimedia/table/normal-menstrual-parameters
- ACOG Committee Opinion 651 (2015). https://pubmed.ncbi.nlm.nih.gov/26595586/
- ACOG FAQ, fertility awareness methods (not readable automatically). https://www.acog.org/womens-health/faqs/fertility-awareness-based-methods-of-family-planning
- Mayo Clinic, rhythm method. https://www.mayoclinic.org/health/rhythm-method/MY01003
- MSD Manual, fertility awareness methods. https://www.msdmanuals.com/professional/gynecology-and-obstetrics/family-planning/fertility-awareness%E2%80%92based-methods-of-contraception
- Apple: https://support.apple.com/en-us/HT210407 · instructions for use v4: https://www.apple.com/legal/ifu/cycle-tracking/4-0/ct-ifu-4-0-en_GB.pdf · https://developer.apple.com/documentation/healthkit/hkcategorytypeidentifier/irregularmenstrualcycles
- Clue: https://support.helloclue.com/hc/en-us/articles/214434406 · https://support.helloclue.com/hc/en-us/articles/16700925119901 · https://support.helloclue.com/hc/en-us/articles/28389082270877 · https://support.helloclue.com/hc/en-us/articles/7955531533844
- Flo: https://help.flo.health/hc/en-us/articles/360015317051 · https://help.flo.health/hc/en-us/articles/360015106672
- Natural Cycles: https://help.naturalcycles.com/hc/en-us/articles/360003339574

Not verified: the wording of ACOG's own page, what Apple and Stardust do when a period is late, and the defaults any app uses when there's no data.
