import { Marked } from 'marked'

// Rich text from the CMS is Markdown. Raw HTML in it is shown as text, so a
// pasted <script> can't run on the site.
const markdown = new Marked({
  renderer: {
    html: ({ text }) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
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
