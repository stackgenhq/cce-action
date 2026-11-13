# CCE Action developer site

This directory is the complete static site published at
<https://stackgenhq.github.io/cce-action/>. It intentionally uses plain HTML and
CSS: there is no site generator, package install, external font, or client-side
JavaScript to maintain.

## Preview locally

From the repository root:

```bash
python3 -m http.server 8000 --directory docs
```

Open <http://localhost:8000>.

## Update the site

- Edit `index.html` for content and `assets/styles.css` for presentation.
- Keep `index.md` as the clean Markdown equivalent for agents and users who prefer plain text. `llms.txt` is the concise, curated site index; do not turn it into a dump of the entire site.
- Keep examples aligned with the versioned files in `../examples/`.
- Link to the action README for exhaustive input/output tables rather than
  duplicating every option on the landing page.
- Preserve the short explanations of static-analysis and IAM-review limits.

A push to `main` that changes this directory runs `.github/workflows/pages.yml`,
which uploads `docs/` and deploys it with GitHub Pages. The workflow can also be
run manually from the Actions tab.
