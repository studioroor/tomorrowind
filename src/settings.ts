import raw from './data/settings.json'
import { safeUrl } from './lib'

/** The details from the CMS, with every link checked by safeUrl. */
const settings = {
  ...raw,
  socialImage: safeUrl(raw.socialImage) ?? '/images/tomorrowind-social.png',
  links: Object.fromEntries(Object.entries(raw.links).map(([k, v]) => [k, safeUrl(v)])) as Record<
    keyof typeof raw.links,
    string | undefined
  >,
  studio: { ...raw.studio, url: safeUrl(raw.studio.url) },
  support: { ...raw.support, url: safeUrl(raw.support.url) },
}
export default settings
