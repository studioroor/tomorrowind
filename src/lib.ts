import { Marked } from 'marked'

const BASE = import.meta.env.BASE_URL.replace(/\/+$/, '')

/**
 * A path on this site with the base it's published under (see astro.config.mjs):
 * withBase('/releases/') is '/tomorrowind/releases/' on GitHub Pages. Other
 * URLs, and paths that already have the base, are returned as they are.
 */
export function withBase(path: string): string {
  if (!BASE || !path.startsWith('/') || path.startsWith('//')) return path
  if (path === BASE || path.startsWith(`${BASE}/`) || path.startsWith(`${BASE}#`)) return path
  return `${BASE}${path}`
}

/**
 * The URL if it's safe to put in an href or src: http(s), mailto or a path on
 * this site. Anything else (javascript:, data:, …) becomes undefined, so a link
 * typed in the CMS can't run a script. Paths on this site get the base.
 */
export function safeUrl(url: string | undefined | null): string | undefined {
  if (!url) return undefined
  const trimmed = url.trim()
  if (/^(\/(?!\/)|#|\.{0,2}\/)/.test(trimmed)) return withBase(trimmed)
  try {
    const { protocol } = new URL(trimmed)
    return ['http:', 'https:', 'mailto:'].includes(protocol) ? trimmed : undefined
  } catch {
    return undefined
  }
}

// Rich text from the CMS is Markdown. Raw HTML in it is shown as text, and
// links and images with an unsafe address lose it, so nothing pasted can run
// on the site.
const markdown = new Marked({
  renderer: {
    html: ({ text }) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
  },
  walkTokens(token) {
    if (token.type === 'link' || token.type === 'image') token.href = safeUrl(token.href) ?? ''
  },
})

export function renderMarkdown(source: string | undefined): string {
  return source ? (markdown.parse(source, { async: false }) as string) : ''
}

/** "9 November 2026" */
export function formatDate(date: Date): string {
  return date.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' })
}

/** The video id from a youtu.be, youtube.com/watch, /embed or /shorts link, or null. */
export function youtubeId(url: string | undefined): string | null {
  if (!url) return null
  try {
    const u = new URL(url)
    const host = u.hostname.replace(/^(www|m)\./, '')
    let id: string | null = null
    if (host === 'youtu.be') id = u.pathname.slice(1)
    else if (host === 'youtube.com' || host === 'youtube-nocookie.com') {
      id = u.searchParams.get('v') ?? u.pathname.match(/^\/(?:embed|shorts|live)\/([^/]+)/)?.[1] ?? null
    }
    return id && /^[\w-]{11}$/.test(id) ? id : null
  } catch {
    return null
  }
}
