# Why Memoir exists, and how it compares

Moved out of the README so the front page stays short. Nothing here is required to install or
use Memoir.

## What it is for

Everything goes through a screen now, and none of it is kept. Not just work: the message from
your mother, the band you played on loop that winter, the flat you almost took, the idea you
have abandoned twice.

The models do have memory. ChatGPT saves memories and reads back your chats, Claude has memory,
coding agents read a file you wrote about yourself. All of it remembers **one version of you:
the one in the chat window.** It knows what you *told* it. It has no idea what you *did*.

Memoir is the other half. Given a few years of it, the questions it can answer stop looking
like search:

> **You told Marco you would read his draft. Three weeks ago.**
>
> **Your mother has brought up the house three times this year. None of it was written down.**
>
> **Every autumn since 2023 you start looking at flats in the same neighbourhood.**

The first is useful, the second is tender, and the third is not possible for anything that
cannot hold years. That is the whole design.

---

## How it compares

Honest version, current as of August 2026. Where a number is somebody else's published figure
it is attributed.

| | Memoir | screenpipe | mem0 | Obsidian | ChatGPT / Claude memory |
|---|---|---|---|---|---|
| **What it captures** | Accessibility text only | Screen text, screenshots, OCR, microphone audio, keystrokes | Nothing: you feed it | Nothing: you type it | What you say in the chat |
| **Who does the work** | Nobody. It watches | Nobody. It watches | You | You | You |
| **Where it lives** | Your Mac, encrypted | Your Mac by default | Self-host or their cloud | Your Mac | Their servers |
| **Disk per month** | ~125 MB, fully indexed | ~30 GB *(their site)* | n/a | n/a | n/a |
| **Ten years of it** | ~15 GB *(projected)* | ~3.6 TB at that rate | n/a | n/a | n/a |
| **Can it cite a source?** | Every claim, always | Search returns the frame | No | The note itself | No |
| **Can an agent write to it?** | **Never.** It may only propose | n/a | Yes | Yes | Yes |
| **Licence** | Open source | Source-available, commercial use needs a licence | Apache-2.0 | Proprietary | Proprietary |

**Where the others are better, plainly:** screenpipe sees far more than we do. Pixels and audio
catch the video call, the diagram, the image-rendered PDF, the app that publishes nothing to
screen readers, and everything said out loud and never typed. Those are real holes in what
Memoir can know, and they are the price of not taking them. It also runs on Windows and Linux,
and Memoir does not.

**Rewind** is not in the table because it is gone: it became Limitless, was acquired by Meta in
December 2025, and the Mac app stopped capturing on 19 December 2025. It is here as an argument
rather than a competitor: the closest thing anyone built to this was switched off by an
acquirer, which is most of why the local-first case matters.

**What Memoir is betting on** is duration, and the row that matters is the storage one. Filming
the screen sets a ceiling in the file format, not in a setting. Text does not. Nobody needs ten
years of support tickets, so the long game and the personal focus are the same decision.
