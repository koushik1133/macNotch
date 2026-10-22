# Prompt Refiner: design note

The user types or dictates a rough prompt ("write a cold email"). Prompt Refiner asks 2–5
clarifying questions, each with suggested answer chips and a free-text field, and the user can skip
them. It then writes a structured prompt for the chosen target (Claude Code, ChatGPT, Gemini, an
image model, or General), lets the user edit it, refine it again or copy it, and keeps a history.
It never runs the prompt.

## What production tools do (research)

| Source | What we took |
|---|---|
| Anthropic **prompt improver** ([docs](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompt-improver), [blog](https://claude.com/blog/prompt-improver)) | Four steps: example identification, initial draft, chain-of-thought refinement, example enhancement. The output is a structured, XML-tagged prompt. We use the "draft, then structure" idea and add examples only when they help. |
| Anthropic **prompting best practices** ([docs](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)) | Be clear and direct (the "golden rule": a colleague with minimal context should be able to follow it), give context and motivation, set a role, separate instructions, context, examples and inputs with XML tags. This shapes the Claude Code layout (`<task>`, `<context>`, `<inputs>`, `<requirements>`, `<constraints>`, `<done_when>`, `<report>`). |
| Anthropic **Console prompt generator** ([docs](https://platform.claude.com/docs/en/prompt-generator)) | Templates with placeholders for the user's own material. Our `inputs` are rendered as `[paste: …]`. |
| **Claude Code best practices** ([docs](https://code.claude.com/docs/en/best-practices)) | "Give Claude a way to verify its work" (tests, build, screenshot), give specific context (files, symptom, scope), and for larger work have it ask you questions first. For the Claude Code target, the questions step always asks how to check the result, and the prompt ends with verification criteria and "show evidence". |
| OpenAI **Deep Research** clarifying and rewriting prompts ([cookbook](https://developers.openai.com/cookbook/examples/deep_research_api/introduction_to_deep_research_api)) | The two-stage flow this feature copies. A clarifier asks only the questions that change the result, never invents preferences, and stays brief. A rewriter turns the request and answers into detailed instructions, must **not complete the task itself**, marks unknowns as open rather than inventing them, and keeps the user's language. |
| OpenAI **meta-prompting** ([cookbook](https://developers.openai.com/cookbook/examples/enhance_your_prompts_with_meta_prompting)) and **prompt optimizer** ([docs](https://developers.openai.com/api/docs/guides/prompt-optimizer)) | A model rewrites a basic prompt into a more detailed one that follows best practices. Optimized prompts need human review, so our result is an editable text field and "Refine again" takes feedback. |
| OpenAI **GPT-4.1 prompting guide** ([cookbook](https://developers.openai.com/cookbook/examples/gpt4-1_prompting_guide)) and **prompt guidance** ([docs](https://developers.openai.com/api/docs/guides/prompt-guidance)) | Recommended section order: Role and Objective, Instructions, Output Format, Examples, Context, final instructions. Markdown headings are the default delimiter. The model should infer intent before asking and only ask when it is blocked. This gives the ChatGPT layout and its closing line ("ask me one short question if something essential is missing"). |
| Google **Gemini prompting strategies** ([docs](https://ai.google.dev/gemini-api/docs/prompting-strategies)) | `<role>` / `<constraints>` / `<context>` / `<task>` tags. Give the context first and the task last ("Based on the information above…"), with an explicit output format and few-shot examples. This gives the Gemini layout. |
| Google **Vertex AI image prompt guide** ([docs](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/image/img-gen-prompt-guide)) | Image prompts cover subject, context and background, style, framing, lighting, lens and camera, quality, and aspect ratio. Negative prompts are plain nouns, not "no …". This gives the image layout: one descriptive paragraph, then `Aspect ratio:` and `Avoid:`. |
| Open source: [linshenkx/prompt-optimizer](https://github.com/linshenkx/prompt-optimizer) (AGPL-3.0) | Read the README only, for the feature set: optimize, compare, iterate, history. **No code was used** because its license doesn't fit this app. Everything here is written from scratch. |
| Apple **FoundationModels** (from the SDK `.swiftinterface`) | `DynamicGenerationSchema` (object, `anyOf` string choices, `arrayOf` with min/max) for guided JSON without the `@Generable` macro, `LanguageModelSession.streamResponse(to:schema:)` for streaming partial JSON, and `prewarm()`. |

## Architecture

```
PromptRefinerDrawerView (508×114 tab)        PromptRefinerPanelView (floating glass panel, 580×560)
        │  refine() / showHistory()                   │ compose → asking (streamed) → answering → refining (streamed) → done
        ▼                                             ▼
PromptRefinerController (@MainActor ObservableObject; history, clipboard, LiveActivity, dictation hooks)
        │
        ▼
PromptRefinerEngine (Sendable struct, nonisolated)
   1. Groq (only if the feature's own opt-in is on AND a Clicky key exists) → MeetingAIBackend.groq, JSON mode
   2. On-device FoundationModels, guided JSON from PromptRefinerSchema → DynamicGenerationSchema, streamed
   3. PromptRefinerTemplates (deterministic: keyword domain detection, question bank, spec defaults)
        │  model fills *fields* only (role, objective, context, requirements, constraints, inputs,
        │  outputFormat, acceptanceCriteria, example | image: subject, setting, style, …, aspectRatio, avoid)
        ▼
PromptRefinerRenderer: fixed per-target layout (Claude Code XML, ChatGPT Markdown, Gemini tags, image paragraph, General Markdown)
```

Key decisions:

- **The model fills fields and Swift does the layout.** The ~3B on-device model is unreliable at
  producing well-formatted long text. It is reliable at short JSON fields under guided generation.
  The layout is deterministic, follows each vendor's recommended format, and the template fallback
  reuses the same renderer.
- **Never executes.** The request goes in `<request>` tags as data. The instructions say "never
  write the email, code or answer itself". The output is checked as well: an objective with a code
  block or over 700 characters is replaced, and JSON samples are dropped. Nothing is sent anywhere
  except the clipboard, plus Groq when the user opted in.
- **Small-model hygiene, learned from the local runs.** In-prompt examples were copied verbatim.
  For instance, an "executive summary" example leaked into every result. So there are no content
  examples. The questions step instead gets *domain hints* from the template bank ("Details often
  missing from this kind of request: audience, goal, tone, length"). Field descriptions avoid
  copyable patterns ("1-4 limits: …" used to be echoed). A post-pass drops meta items ("the prompt",
  "acceptanceCriteria", "skipped the questions"), bare restatements, pasted text in `inputs`, and
  duplicates across fields. It fills empty fields from the templates and appends any user answer
  the model dropped, so every answer survives into the prompt.
- **Latency.** Each step takes about 4–13 s on device. Both steps stream (`streamResponse`): partial
  questions and prompt text appear after about 2–7 s, read-only until the step completes. The
  model is prewarmed when the drawer tab appears, and the refine instructions are prewarmed while
  the user answers. "Skip questions" works during loading too.
- **Privacy.** Groq uses Clicky's key only behind `promptRefiner.allowGroq` (default off). The key
  is read only when the opt-in is on, and `hasKey()` never triggers a keychain prompt. History is
  local JSON in `~/Library/Application Support/SparkV/PromptRefiner/history.json`, at most 200
  entries, newest first. It can be deleted per entry or cleared from the panel, each only after an inline confirmation.
