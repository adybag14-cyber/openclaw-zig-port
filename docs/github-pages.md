# GitHub Pages Deployment

This repository publishes documentation with GitHub Pages via workflow:

- `.github/workflows/docs-pages.yml`

## Deployment Model

- Trigger:
  - push to `main` when docs/workflow files change
  - manual `workflow_dispatch`
- Build:
  - Python + MkDocs + Material theme
  - `mkdocs build --strict`
- Publish:
  - upload Pages artifact from `site/`
  - deploy with `actions/deploy-pages`

## Required Repository Settings

In GitHub repository settings:

1. Open `Settings -> Pages`.
2. Set source to `GitHub Actions`.
3. Ensure Actions are allowed to deploy Pages for this repository.

## Local Preview

Install locally:

```powershell
python -m pip install --upgrade pip
pip install mkdocs mkdocs-material
```

Run local docs server:

```powershell
mkdocs serve
```

Build static site:

```powershell
mkdocs build --strict
```

## Site Entry and Nav

- config: `mkdocs.yml`
- content root: `docs/`
- generated output: `site/` (ignored by git)
