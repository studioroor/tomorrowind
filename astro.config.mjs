import { defineConfig } from 'astro/config'

// The address the site is published at. Images uploaded in the CMS are linked
// from the root (/uploads/…), so publish on its own (sub)domain.
// TODO: placeholder domain, set the real one before going live.
export default defineConfig({
  site: 'https://tomorrowind.studioroor.nl',
})
