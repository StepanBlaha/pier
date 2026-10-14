# pier website

The landing page for [pier](https://github.com/StepanBlaha/pier), live at https://stepanblaha.github.io/pier.
Next.js (static export), React, GSAP, Locomotive Scroll and lucide icons, deployed to GitHub Pages by
`.github/workflows/site.yml` on every push to `main` that touches `site/`.

```bash
npm install
npm run dev                                   # http://localhost:3000
NEXT_PUBLIC_BASE_PATH=/pier npx next build     # what CI builds; output in out/
```

Mascot images in `public/mascot/` are generated from the original artwork; screenshots in
`public/shots/` come from `assets/screenshots/` in the repo root.
