# Tomorrowind website

The website for [Tomorrowind](https://github.com/studioroor/tomorrowind), a House Hlaalu colony
builder for OpenMW: what the mod is, the trailer, a download button with installation steps,
release notes for every version, videos, and a word about Studio Roor and Buy Me a Coffee.

It's a static [Astro](https://astro.build) site, editable in
[Drikus CMS](https://github.com/studioroor/drikus-cms) (built from its Astro starter).

```sh
bun install
bun run dev          # http://localhost:4321
bun run build        # static site in dist/
```

## What's edited where

| In the CMS   | Stored in                              | Shown on                                        |
| ------------ | -------------------------------------- | ----------------------------------------------- |
| **Releases** | `src/content/releases/*.md`            | `/releases/`, `/releases/<slug>/`, the homepage |
| **Homepage** | `src/content/pages/home.json` (blocks) | `/`                                             |
| **Details**  | `src/data/settings.json`               | links, Studio Roor, support, footer             |
| Uploads      | `public/uploads/`                      | `/uploads/…`                                    |

The CMS configuration is [`.drikus/config.yml`](.drikus/config.yml). When you add a field, add it
there and on the Astro side: [`src/content.config.ts`](src/content.config.ts) for releases,
[`src/components/Sections.astro`](src/components/Sections.astro) for homepage blocks.

## A new release

Add a release in the CMS (or a file in `src/content/releases/`) with the version, the date, the
link to the zip under **Assets** on the GitHub release, and the YouTube link if there's a video.
The newest release with a download link is what every **Download** button on the site points at,
so publishing the post is all it takes to switch the site over.

## Assets

- `public/images/`: the dawn still, the social image and the colony timelapse, from the mod's
  `art/` folder.
- `public/fonts/MysticCards.ttf`: the Morrowind-style font that ships with OpenMW, under the SIL
  Open Font License (`MysticCardsFontLicense.txt`). Body text is Alegreya from Google Fonts.
- YouTube videos load only when someone presses play, from `youtube-nocookie.com`.

## Hosting

GitHub Pages is set up in [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml): in the
repository go to _Settings → Pages_ and set _Source_ to **GitHub Actions**. Use its own domain or
subdomain (uploads are linked from the root) and set it as `site` in `astro.config.mjs`.
