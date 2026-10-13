---
version: "0.2"
source: "Slipdock wiki W-106"
---

# AI in Practice: rubric v0.2

**This rubric and the PRD are the source of truth for the build.** Where they differ from earlier comments on #585, they win. v0.2 applies David's answers to the v0.1 open questions (see "Decisions log" at the end). Still subject to external review before launch.

## Purpose

**AI in Practice** is a framework, published by DSC at `ai-in-practice.dsc.net`. It is a conversation starter about how one senior person works with AI, at whatever level they are. It gives the person a developmental view of themselves, and gives a recruiter, CEO or board member an evidence-based profile, recommended next steps and the questions worth asking next. It is never a pass/fail test, a ranking or a hiring decision.

**Who it is for:** senior people, meaning CxO and Director level, plus board members and non-executive directors.

## Principles

1. **Evidence is a specific instance.** What happened, roughly when, what this person did, and what came of it. Tool names, vocabulary, job titles and views about the industry earn nothing on their own.
2. **Recent counts most.** The last 12 months weigh most heavily because the field moves fast. Older examples count where they show judgement that still applies.
3. **Credit their own part, at the level their role implies.** For a CEO, sponsoring, funding and steering is real contribution. For a Director, hands-on detail is expected. "My team built X" earns credit for what the person decided, asked for, or changed.
4. **One follow-up, then move on.** A vague answer gets one request for an instance. If it is still vague, record thin evidence and continue. Pressing harder makes it feel like an interrogation and adds little.
5. **Judgement beats volume.** A well-reasoned decision to use less AI, or none, for a given piece of work is credited as fully as heavy use.
6. **Judge the substance.** Spelling, fluency, accent, transcription errors and English as a second language never affect the assessment.
7. **Context matters.** Someone in a small company, or a regulated sector with tight limits on experimentation, is judged against what was possible for them.
8. **Confidentiality is respected.** People are told at the start they can anonymise clients and give figures as ranges. An anonymised example counts the same as a named one.
9. **No philosophy.** Abstract questions ("what do you think AI means for society?") are never asked. Every question asks about something the person did, decided or saw.

## How the assessment is expressed

**No scores appear anywhere in either report.** No overall number and no per-area number or label.

**Internally,** the model places each area at one of four levels, with a confidence rating, so its judgements are consistent between people. These levels guide the written descriptions and are never shown.

| Internal level | Meaning |
|---|---|
| Early | Little or no first-hand evidence |
| Developing | Some first-hand experience, mostly occasional or general |
| Capable | Regular, specific, reflective experience with outcomes |
| Advanced | Shapes how others work; judgement visible across several cases |
| Insufficient evidence | Not enough was said to place them |

**Confidence:** high (several specific instances that agree), medium (one solid instance, or several thin ones), low (inferred from general statements). In the reports, confidence is expressed in words ("based on one detailed example", "little concrete evidence was given here").

**In the reports,** each area gets a short written description of what the evidence showed, in plain language, with the confidence stated in words. Unevenness is described explicitly: someone can be well advanced in personal use and only starting on leading adoption, and the shape is often more useful than any single area.

## Role calibration

The five areas are the same for everyone. Role sets what good looks like and how much detail is requested.

| Role group | Depth expected | Where the emphasis falls |
|---|---|---|
| CEO / GM | Breadth and decisions | Where AI goes across the business, what was funded or stopped, how they hold leaders to account |
| Finance (CFO) | Business cases and controls | Cost and return, measurement, audit, controls on AI-driven processes, finance team's own use |
| Operations (COO) | Process and quality | Error rates, throughput, exception handling, where humans stay in the loop |
| Commercial (sales, marketing) | Customer-facing use | Content and outreach at scale, brand risk, measurable effect on pipeline or conversion |
| People (HR) | People decisions and data | Use in hiring and performance, employee data, skills, job concerns |
| Technology and product (CTO, CPO) | Technical depth | Architecture, evaluation, data quality, cost per transaction, build or buy, vendor dependence, running in production at scale |
| Board / NED | Oversight | Questions asked of management, what they challenged and what changed, the board's own capability |

**Director vs CxO:** a Director is expected to give hands-on detail within their own function. A CxO is expected to show decisions across functions and the reasoning behind priorities. Neither is expected to do the other's job.

**Request depth by role:** technology and product roles are asked for mechanism (how it worked, how it was measured, what it cost per unit). Board members are asked for the question they put to management and what happened next. Everyone else sits between, asked for outcome and how they knew.

## Area 1: Understanding

**Looking for:** a working mental model of what current AI does well and badly, good enough to make sound decisions in their role. Technical depth is required only for technology and product roles.

**Evidence that counts:** explaining a real case where AI output was wrong or poor and why; knowing what drives quality and cost in their own use; knowing how they would check an output that mattered.

| Level | Signals |
|---|---|
| Early | Treats AI as an oracle or a search engine, or rejects it from hearsay. Cannot describe a real failure. |
| Developing | Knows the headline limitations (invents things, can be out of date) in general terms. Struggles to connect them to their own work. |
| Capable | Describes specific instances where AI fell short in their work, why it happened, and what they did. Understands that quality depends on the context provided and on checking. |
| Advanced | Reasons about trade-offs in their area: when a cheaper or faster option is good enough, when data quality is the real constraint, what changes as capability improves. Explains this plainly to colleagues. |

**Watch for:** fluent jargon with no instance behind it; confident predictions stated as fact.

**Guidance questions** (illustrate the ground to cover; the model writes its own):
- A time an AI tool gave them, or their team, a wrong answer, and how they spotted it.
- What they do before relying on an output that matters.
- *(Technology and product)* How they decided something in production was good enough, and how they kept checking after launch.

## Area 2: Personal use

**Looking for:** how AI actually shows up in the person's own working week.

**Evidence that counts:** specific recent tasks; what they give it to work with; how they check results; what they have stopped doing by hand; what they tried and dropped, and why.

| Level | Signals |
|---|---|
| Early | Rarely or never uses it, or tried it a few times. |
| Developing | Occasional one-off tasks (a draft, a summary). Little context given; light checking or none. |
| Capable | Regular use across several kinds of work. Supplies real material (documents, data). Has a checking habit. Can say what it does well and badly for them. |
| Advanced | Has repeatable ways of working: saved instructions, connected tools, multi-step tasks handed over. Matches how much they hand over to the stakes. Others adopt their methods. |

**Role notes:** board members and some CxOs may reasonably use it less. Credit clear reasoning about where it fits their work. Volume is never the measure.

**Guidance questions:**
- The last piece of real work where they used AI: what they gave it and what they did with the result.
- Anything they now hand over completely, and how they know it is done properly.
- What they tried and stopped using, and why.

## Area 3: Applying AI to the business

**Looking for:** a track record of turning AI into outcomes in their area, and sound judgement about where it does not belong. **Risk is assessed here, from decisions only.**

**Evidence that counts:** an initiative they sponsored, led or approved: the problem, why AI, what it cost, how success was measured, what happened, what they would change. A case they stopped, limited or declined, and the reason. What was checked before AI touched customers, sensitive data or a regulated process.

| Level | Signals |
|---|---|
| Early | No examples, or describes vendor features and announcements as achievements. |
| Developing | Pilots or experiments, but cannot say what changed or how it was measured. |
| Capable | At least one initiative described from problem to measured outcome, including cost and what went wrong. At least one concrete case of setting a limit, with the reason. |
| Advanced | Treats AI as a portfolio: places bets by value and risk, stops what does not work, shows results at scale. Checks on data, quality and compliance are part of how the work runs. |

**Risk handling (important):**
- Never ask about governance, ethics or responsible AI in the abstract. The right-sounding answer is obvious and tells you nothing.
- Infer risk judgement from what they did: the limit they set, the check they insisted on, the project they slowed down or killed.
- A statement of principle with no instance earns nothing.

**Guidance questions:**
- One AI initiative in their area they were close to: the problem, and how they knew whether it worked.
- A time they decided not to use AI for something, or held it back, and why.
- What had to be true before it went live, and who checked.
- *(Board / NED)* The most useful question they have put to management about AI, and what happened as a result.

## Area 4: Leading adoption

**Looking for:** how they bring other people along.

**Evidence that counts:** what they did to change how their team works; how they handled resistance or worries about jobs; what they did about skills; what they measure; what they do themselves that others see.

| Level | Signals |
|---|---|
| Early | Leaves it to individuals or to IT. No view on it. |
| Developing | Has encouraged use (licences, a training session) with little follow-through or measurement. |
| Capable | Specific actions that changed team practice, with evidence people took it up. Has dealt with a real person's concern. |
| Advanced | Has changed roles, processes or hiring because of AI, with care for the people affected. Can show the change lasted. |

**Role notes:** for board members, this covers how they pushed management on adoption and what the board has done about its own capability.

**Guidance questions:**
- Something they did that changed how their team uses AI day to day, and how they know it stuck.
- A team member worried about what AI means for their job, and what they did.
- *(Board / NED)* What the board has done to make sure it can judge management's AI plans.

## Area 5: Attitude

**Looking for:** a realistic, curious, grounded stance. Judged mainly from how they talk across the whole conversation, plus one direct question at the end.

**Signals**
- *Realistic:* weighs gains against costs, is specific about uncertainty, changes their view when evidence changes.
- *Hype-driven:* sweeping claims, predictions as facts, AI as the answer to every question.
- *Dismissive:* blanket rejection, based on old or second-hand experience.
- *Curious:* tries new things personally, learns from people doing the work.

| Level | Signals |
|---|---|
| Early | Strongly hype-driven or strongly dismissive. |
| Developing | Leans one way; views are generic. |
| Capable | Balanced and specific. |
| Advanced | Balanced, specific, and can point to a view they changed because of their own experience. |

Enthusiasm is never credited as a virtue in itself.

**Guidance questions:**
- How they keep up, and the last thing they tried because of something they read or heard.
- A view about AI they held a year ago and have since changed.

## Conversation design

- **Length:** 20 to 25 minutes. About 10 to 14 main questions in total, adapting to answers. Fewer if early answers are rich.
- **Questions are the model's own.** The guidance questions in each area show the ground to cover. The model writes its questions from what the person has already said, and never reads a script.
- **Order:** start with personal use (concrete, easy to answer), then applying it to the business, leading adoption, and close on attitude. Understanding is assessed throughout and probed directly only if evidence is thin.
- **Set-up screen:** as specified in the PRD (the PRD, section 7): role, text or voice, conversation-starter statement, one attempt, anonymising, data handling, and (recruiter mode) that the recruiter can see whether it was completed.
- **Tone:** plain, brief questions. No praise or judgement during the conversation. Nothing about the assessment is revealed until the end. The word "interview" is never used.

## Reports

Both reports open with a **short overall summary** (two or three sentences), followed by a **fuller overall paragraph**. No scores anywhere.

**Candidate report (private):**
- short overall summary, then the fuller paragraph
- a written description for each of the five areas, with confidence in words
- what they are doing well, with the evidence
- the main gap
- **recommended next steps:** practical things to try, starting with one for the next two weeks, and how they will know if it helped
- two or three suggestions for further reading, chosen from David's curated list
- a note on what the assessor report contains

**Assessor report (released by the candidate as a signed PDF):**
- header: role, date, text or voice, link type, and the statement that this is a conversation starter, identity is not checked, and it is one input to human judgement
- short overall summary, then the fuller paragraph, including where the profile is uneven
- per area: a written description, with short quotes from the person's own answers that support it and confidence in words
- per area: what a strong answer would have included for this role, and where this one fell short
- **recommended next steps:** what to explore with this person next
- two or three follow-up questions to ask in person, each with what to listen for

The candidate sees the assessor report before releasing it.

## Further reading

David curates the list, and Claude's suggestions are input to it. The model chooses only from that list and never invents a reference. Each entry needs: title, link, one line on who it suits (role and area), and the date it was last checked.

## Fairness and bias checks

- **David's own test:** before launch, David answers it himself. If the rubric would not mark him down in any area, it is probably tilted toward his profile.
- **Language:** test with non-native English speakers and with voice transcripts containing errors, and confirm the descriptions do not shift.
- **Sector and size:** test with someone from a regulated sector and someone from a small company, and confirm context is credited.
- **Role spread:** test at least one person per role group before launch.
- **External review:** two recruiters, one or two other CTOs, ideally one person from AI governance or academia.

## Decisions log

13 Oct, David's answers to the v0.1 open questions:
1. **Overall score:** none. A short overall summary in words plus a fuller paragraph.
2. **Per-area rating:** written description only. Levels exist internally for consistency and are never shown.
3. **Area weights by role:** not needed, since there is no score.
4. **Example questions:** guidance only. The model writes its own.
5. **Next steps:** recommended next steps in both reports (candidate: what to work on; assessor: what to explore next).
6. **Further reading:** David curates the list, taking Claude's suggestions into account.

