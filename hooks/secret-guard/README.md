# secret-guard

A `PreToolUse` hook that refuses to write a credential into a file.

Before Claude Code writes or edits anything, this hook reads the tool call and
blocks it if the content carries a credential that is unmistakably real: an AWS
access key, a GitHub, Slack or Stripe token, a Google, OpenAI or Anthropic key,
a PEM private key block, a signed JWT. The write never happens, and Claude is
told what was found so it can use an environment variable instead.

```
Cette écriture contient un identifiant qui semble réel :
  - AWS access key (AKIAQ3RJ…T4C)
```

It reports the shape, never the whole credential — a scanner that prints the
secret it just blocked has defeated itself.

## What it will not do

Guess. A scanner that blocks every long base64 string gets switched off within
a week, and a switched-off scanner protects nothing. So it matches
issuer-specific shapes only, and it stays quiet on anything that announces
itself as an example: `AKIAXXXXXXXXXXXXXXXX`, `YOUR_TOKEN_HERE`,
`${AWS_ACCESS_KEY_ID}`, `<your-token>`, an empty value in a `.env.example`.

That trade-off is the whole design, and it is the reason the suite spends as
many assertions on what must *pass* as on what must block.

## Deliberate choice: it reads the payload as text

The hook does not parse the JSON on its stdin. `jq` is not everywhere, a
hand-rolled JSON parser in shell is a liability, and none of these credential
shapes contains a character that JSON escapes — a key survives encoding
unchanged. Scanning the raw payload is fewer moving parts, and a key hidden in
a field the hook didn't think to look at is still caught.

## Letting one case through

Add `secret-guard: allow` on the same line. The rest of the write is still
checked.

```php
$legacy = "AKIA...";  // secret-guard: allow
```

## Install

In `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [{ "type": "command", "command": "bash .claude/hooks/secret-guard.sh", "timeout": 10 }]
      }
    ]
  }
}
```

It is not a replacement for a scanner on your repository's history, and it
cannot see a secret that reaches the file by another route — a `Bash`
heredoc, an editor, a colleague. It covers the one path Claude Code writes
through, which is the path you are adding when you let an agent edit files.

## Tests

```bash
bash hooks/secret-guard/test.sh
```

55 assertions: the contract, one blocking case per issuer, the placeholder and
prose cases that must pass, the tool filter, the masking, and the opt-out. No
credential appears whole in the test file — each is assembled at run time, so
the suite neither trips the hook it tests nor arms a repository scanner.

Verified against Claude Code 2.1.323.
