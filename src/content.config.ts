import { defineCollection } from 'astro:content'
import { glob } from 'astro/loaders'
import { z } from 'astro/zod'
import { safeUrl } from './lib'

// Addresses with another scheme than http(s) or a site path are dropped.
const link = z.string().optional().transform((u) => safeUrl(u))

// Mirrors the "releases" collection in .drikus/config.yml. The CMS writes the
// fields as frontmatter and the rich text below it.
const releases = defineCollection({
  loader: glob({ pattern: '*.md', base: './src/content/releases' }),
  schema: z.object({
    title: z.string(),
    // A YAML version like 0.3 would otherwise come in as a number.
    version: z.coerce.string(),
    date: z.coerce.date(),
    summary: z.string().optional(),
    download: link,
    youtube: link,
    cover: link,
    draft: z.boolean().default(false),
  }),
})

export const collections = { releases }
