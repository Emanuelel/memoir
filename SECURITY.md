# Security

Memoir holds a record of someone's life in a file on their own machine. Report anything that
weakens that, and please do it privately first.

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this repository. That
opens a channel only the maintainers can read.

Please include what you did, what happened, and the macOS version. A proof of concept helps and
is never required. You will get a first reply within seven days.

Do not open a public issue for a vulnerability. Do not include real captured data, database
files, or a recovery key in a report. Describe them instead.

## What is in scope

- Anything that reads the memory without the user's key: escaping the encrypted container,
  recovering the key off disk, or reading the database from another user account.
- Anything that writes to the memory through a path that is supposed to be read-only,
  particularly the MCP server, where an agent that could change the record would break the
  guarantee the whole product rests on.
- Capture reaching content that is meant to be excluded: password managers, credential prompts,
  and anything on the user's own exclusion list.
- Anything that sends data off the machine while the cloud brains are off.

## What is not

- Physical access to an unlocked Mac. Encryption protects the file, not the logged-in session;
  this is stated plainly in [PRIVACY.md](PRIVACY.md) rather than papered over.
- Anything that requires the user to be persuaded to disable a protection.
- Findings in third-party software. There are no third-party dependencies to report against.

## Supported versions

The `main` branch is the only supported version. There are no published releases yet.
