import { defineConfig } from 'astro/config'

// Published on GitHub Pages at https://studioroor.github.io/tomorrowind/.
// Content keeps root paths (/images/…, /uploads/…) and the site adds `base`
// to them (withBase in src/lib.ts). With a custom domain: set `site` to it,
// set `base` to '/', and add the domain under Settings → Pages.
export default defineConfig({
  site: 'https://studioroor.github.io',
  base: '/tomorrowind',
})
