# tools/

## validate-templates.py

Checks the template library holds together. Run from the repo root:

```bash
python3 tools/validate-templates.py
```

Exits non-zero on failure, so it works as a PR gate.

Checks performed:

1. **YAML syntax** on every `.yml` / `.yaml` file.
2. **Template reference integrity.** Every `template:` path resolves.
   `jobTemplate:` / `buildJobTemplate:` values are *parameters* consumed by
   `templates/stages/*.yml`, so they resolve relative to the stage template,
   not relative to the pipeline that writes them — the checker accounts for this.
3. **Orphan check.** Templates that nothing references — reported, not failed.
   shims must forward every parameter the merged pipeline declares, or
   consumers silently lose settings.
4. **Doc links.** Relative links in Markdown resolve to real files.

Nothing here catches a *semantic* error — a stage that depends on the wrong
stage still passes. It catches the class of breakage that a file move or
rename causes, which is what previously only surfaced when a consumer's
build failed.
