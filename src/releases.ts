import { getCollection } from 'astro:content'

/** Published releases, newest first. Releases marked "Hidden" in the CMS are left out. */
export async function publishedReleases() {
  const releases = await getCollection('releases', (r) => !r.data.draft)
  return releases.sort((a, b) => b.data.date.getTime() - a.data.date.getTime())
}

/** The newest release that has a download: what the Download buttons point at. */
export async function latestRelease() {
  return (await publishedReleases()).find((r) => r.data.download)
}
