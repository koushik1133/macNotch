# Job Search Operations Agent: design note

## What production tools do (research summary)

| Tool | How it captures jobs | How "applied" is inferred | Fit / match |
|---|---|---|---|
| Simplify Copilot | Browser extension reads the posting it already knows (its own job DB) or the user saves it from the popup | After autofill + submit, Copilot asks to add the job to the tracker; jobs in its DB are tracked automatically ([help: Job Tracker](https://help.simplify.jobs/en/articles/2140179-using-the-job-tracker), [Copilot autofill](https://help.simplify.jobs/articles/2415391-using-copilot-to-autofill-applications), [custom applications](https://help.simplify.jobs/en/articles/9861158-adding-custom-applications)) | Match score in the extension |
| Huntr | Chrome extension "Save to Board" from career pages and hundreds of job sites ([Huntr extension](https://help.huntr.co/en/articles/9859408-the-huntr-chrome-extension)) | Manual stage moves; CSV import/export | Resume keyword check |
| Teal | Extension saves from LinkedIn/Indeed/Glassdoor; tracker with status, follow-up dates, salary ([review](https://www.unite.ai/tealhq-review)) | Manual status | Keyword "match" vs JD |
| Jobright | Job feed with a 0–100 match score from skills, experience/seniority, industry, salary; report: overall fit, skills alignment, keyword gaps, "why it fits" ([AI Job Matcher](https://jobright.ai/ai-job-match), [resume matcher](https://jobright.ai/tools/resume-job-matcher)) | Tracks applications made through it | Weights not published |
| Jobscan | Paste resume + JD | n/a | Match rate 0–100 weighted by priority: hard skills (weighted much higher) > education (if advanced degree required) > job title > soft skills > other keywords; repeated JD terms count more; exact wording matters; target ~75–80 % ([Jobscan tutorial](https://jobscan.co/jobscan-tutorial), [match rate](https://www.jobscan.co/blog/what-jobscan-match-rate-should-i-aim-for/)) |
| Resume-Matcher (OSS, Apache-2.0) | Paste | n/a | Keyword extraction (spaCy/NLTK/textacy) + embedding cosine similarity ([summary](https://www.sourcepulse.org/projects/1896362)) |
| ESCO research | n/a | n/a | Skill extraction = match spans to a skills taxonomy (ESCO, ~13.9k skills) via embeddings/LLM re-ranking ([arXiv 2307.03539](https://arxiv.org/pdf/2307.03539), [arXiv 2209.08071](https://arxiv.org/pdf/2209.08071)) |

Key takeaways that shaped the build:

1. Every production tracker relies on *seeing the page* (extension DOM access). We have no extension, so we do the
   equivalent from the OS: a window screenshot (ScreenCaptureKit) + Vision OCR + the browser's URL/title over Apple
   Events (`URL of active tab of front window` for Chrome/Arc/Edge/Brave, `URL of front document` for Safari;
   Firefox has no scripting) ([leancrew](https://leancrew.com/all-this/2017/04/getting-urls-from-safari/),
   [KM forum](https://forum.keyboardmaestro.com/t/get-current-window-url-from-chrome-or-safari/7518)).
2. "Applied" is inferred from the **confirmation page** (or the confirmation email), never from clicking "Submit":
   - Greenhouse: `job-boards.greenhouse.io/<board>/jobs/<id>/confirmation`, "Thank you for applying… Your application
     has been received" ([example](https://job-boards.greenhouse.io/alma/jobs/8104666002/confirmation)).
   - Lever: `jobs.lever.co/<company>/<uuid>/thanks`, "Application submitted!".
   - Workday: pop-up "You have submitted" / "Application Submitted"; Candidate Home "My Applications"
     ([UW HR](https://hr.uw.edu/talent/?p=6383), [City Utilities FAQ](https://www.cityutilities.net/m/faq?cat=47)).
   - Indeed: on-screen confirmation + confirmation email ([Indeed help](https://support.indeed.com/hc/en-au/articles/204652920)).
   - LinkedIn Easy Apply: in-modal "Your application was sent to <Company>" ([LinkedIn help](https://www.linkedin.com/help/linkedin/answer/a512353)).
   We score phrases ("application submitted", "thank you for applying", "we received your application",
   "your application was sent to", …) plus ATS URL shapes, and penalise pages that still show an un-submitted form
   ("Submit application" button, required-field markers).
3. Same-job verification: compare URL (same host + same job id / path prefix; Greenhouse/Lever confirmation URLs
   extend the posting URL), normalised company (token containment + edit-distance ratio, legal suffixes stripped), and
   title token similarity. LinkedIn's "sent to <Company>" gives the company.
4. Fit = Jobscan-style weighted priorities, made explainable like Jobright's breakdown:
   hard skills 45 % (required count double vs preferred, frequency-weighted), experience 20 %, keyword coverage 15 %,
   education 10 %, title 10 %. Components without data (e.g. no years stated) are dropped and the weights
   renormalised instead of being scored as a pass; the explanation says so.
5. Structured fields follow schema.org/Google `JobPosting` (title, hiringOrganization, jobLocation, baseSalary,
   employmentType, validThrough) ([Google JobPosting docs](https://developers.google.com/search/docs/appearance/structured-data/job-posting)).
6. Response-date heuristic: startup-style ATS (Greenhouse, Lever, Ashby, Workable) +7 days; enterprise ATS
   (Workday, iCIMS, Taleo, SuccessFactors) and job boards +14 days; Easy Apply / Indeed +10. A reminder is scheduled
   only when notifications are already authorized (`notificationSettings()`); we never ask.

## On-device first

- Text: PDFKit (`PDFDocument.string`, OCR of rendered pages for scanned PDFs), DOCX = ZIP → `word/document.xml`
  parsed with `XMLParser` (`w:t` runs, `w:p`/`w:br`/`w:tab`) per ECMA-376, unzip via `/usr/bin/unzip -p`
  (fallback `NSAttributedString` DOCX importer), TXT/RTF via Foundation.
- Skills: deterministic dictionary (≈350 canonical skills with aliases, word-boundary regex, case rules for short
  tokens such as "Go", "R", "C") — always runs; FoundationModels with `DynamicGenerationSchema` (via the app's
  `MeetingAISchema` / `MeetingAIBackend.onDevice`) refines the structured profile and the posting. Model output is
  **grounded**: a skill/company/title is kept only if it occurs in the source text.
- Groq: only behind `jobAgent.useGroq` (default off), text only (OCR text, never the screenshot), key from
  `ClickyKeychain`, request goes only to api.groq.com through `MeetingAIBackend.groq`.

## Tailoring is truthful

Suggestions come only from text already in the resume: reorder bullets by JD relevance, surface skills that appear in
experience but not in the skills section, mirror the JD's wording for a skill the resume already shows under an
alias ("CI/CD" ↔ "continuous integration"), and a summary rebuilt from profile facts. Missing skills are listed as
gaps with "add only if true". Optional on-device rewording is rejected if it adds any number, skill or proper noun not
already in the resume.

## Hotkey

fn + Control, both held then released (NSEvent global+local `flagsChanged`/`keyDown` monitors, like
`ClickyHotkeyMonitor`; observe-only). Any other key or modifier during the hold cancels. Plain-fn dictation is
protected by a one-line change in `PushToTalkMonitor` (see the integration notes in the final report).

## Licensing

No code or assets from commercial apps were used. All logic is original; the techniques are from the public docs and
papers above. No third-party code is vendored.
