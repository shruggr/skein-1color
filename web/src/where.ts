/**
 * Where a page is served: `<base>/<app>/color/<page>/…`, where `<base>` is
 * the instance's origin (`https://<handle>.<host>`) or a host's dev form
 * (`http://127.0.0.1:8100/@<handle>`). The app name is the path segment
 * before `color/<page>`, so the pages work under any embedding app.
 */
export const PAGES = ["deploy", "tokens"] as const;
export type Page = (typeof PAGES)[number];

export interface Where {
  /** The instance's base URL, no trailing slash: what its routes (`/sendMessage`, `/explore`) are under. */
  base: string;
  /** The embedding app's name: its box, and its heads' prefix. */
  app: string;
  page: Page;
}

/** The page's place from its URL; undefined when the path is not `…/<app>/color/<page>[/…]`. */
export function whereOf(href: string): Where | undefined {
  const u = new URL(href);
  const segs = u.pathname.split("/").filter((s) => s !== "");
  for (let i = segs.length - 2; i >= 1; i--) {
    const page = segs[i + 1] as Page;
    if (segs[i] !== "color" || !PAGES.includes(page)) continue;
    const app = decodeURIComponent(segs[i - 1]!);
    const prefix = segs.slice(0, i - 1).join("/");
    return { base: u.origin + (prefix ? `/${prefix}` : ""), app, page };
  }
  return undefined;
}
