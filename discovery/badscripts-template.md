# Bad Scripts Generator

You are working in the `discovery/` lane of a clean-room shell linting project. Your job is to generate intentionally broken shell scripts based on your knowledge of POSIX shell grammar and bash language semantics. The scripts should contain mistakes that a person learning shell scripting might make. The purpose is to run these scripts through a black-box analysis tool to discover what numeric diagnostic codes it produces.

## Hard Provenance Rules

- Do not read or rely on ShellCheck source code.
- Do not read or rely on ShellCheck wiki pages.
- Do not read or rely on ShellCheck documentation examples.
- Do not reuse ShellCheck diagnostic wording.
- Do not copy or adapt example snippets from ShellCheck materials.
- Do not browse the web for ShellCheck guidance.
- Treat the ShellCheck binary as an oracle for numeric codes only.

## Allowed Inputs

- POSIX.1-2024 Shell Command Language specification (IEEE Std 1003.1)
- Bash Reference Manual (GNU)
- General knowledge of how people write broken shell scripts in practice

## Constraints

- Each script must start with a shebang line (`#!/bin/sh` or `#!/bin/bash` as appropriate)
- Scripts should be short (2-15 lines)
- Generate scripts for BOTH `sh` and `bash` modes
- Aim for variety — do not repeat the same mistake pattern
- Think like a beginner or a hurried programmer making real mistakes, not like someone trying to exercise a linter
- Try to use as many shell features and their variations as you can in a single script
- Use terrible best practices when writing the scripts
- Do not target specific numeric ShellCheck codes; the repo will scan and deduplicate discoveries after generation

## Approach

Write {{SCRIPTS_PER_CATEGORY}} scripts per area below. These areas come from sections of the POSIX Shell Command Language spec and the Bash Reference Manual — they represent the building blocks of shell scripts where mistakes naturally occur.

1. **Compound commands** (POSIX 2.9.4 / Bash 3.2.5): Write scripts where `if`/`then`/`elif`/`else`/`fi`, `case`/`esac`, `while`/`until`/`do`/`done`, or `for`/`do`/`done` structures are incomplete, misnested, or have missing keywords.
2. **Quoting** (POSIX 2.2 / Bash 3.1.2): Write scripts with unmatched quotes, confused nesting of single and double quotes, or strings that are left open across line boundaries.
3. **Here-documents** (POSIX 2.7.4 / Bash 3.6.6): Write scripts where here-document delimiters are missing, misindented, or where the document body is not properly terminated.
4. **Redirections and file descriptors** (POSIX 2.7 / Bash 3.6): Write scripts with malformed redirections — wrong operator combinations, missing targets, duplicated descriptors that reference non-existent fds, or nonsensical redirect syntax.
5. **Word expansions** (POSIX 2.6 / Bash 3.5): Write scripts with broken parameter expansions, malformed arithmetic expansions, bad command substitutions, or incorrectly nested expansion syntax.
6. **Function definitions** (POSIX 2.9.5 / Bash 3.3): Write scripts with syntactically invalid function definitions — missing bodies, invalid names, or confused syntax between POSIX and bash function styles.
7. **Pipelines and lists** (POSIX 2.9.2-2.9.3 / Bash 3.2.3-3.2.4): Write scripts with dangling pipes, empty pipeline segments, malformed && / || chains, or misused control operators.
8. **POSIX vs bash portability**: Write scripts that use bash-only syntax (`#!/bin/sh` shebang) or POSIX syntax in ways that conflict with bash expectations (`#!/bin/bash` shebang). Think about features that exist in one but not the other.
9. **Assignments and variables** (POSIX 2.9.1 / Bash 3.4): Write scripts with broken variable assignments — spaces around `=`, bad array syntax, readonly violations, or export misuse.
10. **Token recognition and special characters** (POSIX 2.3-2.4 / Bash 3.1): Write scripts that confuse the tokenizer — reserved words in wrong positions, unescaped special characters, broken escape sequences, or metacharacter misuse.

## Output Format

Return a JSON object with a single key `"scripts"` containing an array. Each element must have:

- `"filename"`: a descriptive filename (e.g., `"unclosed-dquote-sh.sh"`)
- `"shell"`: `"sh"` or `"bash"`
- `"category"`: which category number from above (1-10)
- `"script"`: the full script content (with `\n` for newlines, starting with the shebang)

Do NOT run any commands or write any files — just return the JSON.
