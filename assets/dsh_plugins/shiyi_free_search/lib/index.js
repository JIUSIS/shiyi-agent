import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { defineTool } from "@deepseek-ai/dsh-tools";

const USER_AGENT =
  "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126 Safari/537.36";
const ACCEPT_LANGUAGE = "zh-CN,zh;q=0.9,en;q=0.8";
const DEFAULT_CONFIG = Object.freeze({
  provider: "auto",
  region: "cn-zh",
  bingMarket: "zh-CN",
});
const PROVIDERS = new Set(["auto", "bing", "ddg", "ddg-lite", "deepseek"]);

function unquoteYamlScalar(value) {
  const text = String(value ?? "").trim();
  if (text.length < 2) return text;
  const quote = text[0];
  if ((quote === '"' || quote === "'") && text.at(-1) === quote) {
    return text.slice(1, -1);
  }
  return text;
}

function readPatchPlugins(filePath, layer) {
  let text;
  try {
    text = fs.readFileSync(filePath, "utf8");
  } catch {
    return [];
  }
  const lines = text.replaceAll("\r\n", "\n").split("\n");
  const plugins = [];
  for (let i = 0; i < lines.length; i += 1) {
    const start = lines[i].match(/^(\s*)-\s+id:\s*(.+?)\s*$/);
    if (!start) continue;
    const indent = start[1].length;
    let end = i + 1;
    while (end < lines.length) {
      const next = lines[end].match(/^(\s*)-\s+/);
      if (next && next[1].length <= indent) break;
      end += 1;
    }
    const block = lines.slice(i, end);
    const nameLine = block.find((line) => /^\s*name:\s*/.test(line));
    if (!nameLine) {
      i = end - 1;
      continue;
    }
    const disabledLine = block.find((line) => /^\s*disabled:\s*/.test(line));
    plugins.push({
      id: unquoteYamlScalar(start[2]),
      name: unquoteYamlScalar(nameLine.replace(/^\s*name:\s*/, "")),
      disabled: /:\s*true\s*$/i.test(disabledLine ?? ""),
      layer,
    });
    i = end - 1;
  }
  return plugins;
}

function readProfileBundles(profileDir) {
  try {
    const root = JSON.parse(
      fs.readFileSync(path.join(profileDir, "package.json"), "utf8"),
    );
    const bundles = root?.dsh?.profile?.bundles;
    return Array.isArray(bundles) ? bundles.map(String) : [];
  } catch {
    return [];
  }
}

function readPluginDirectories(directory, layer) {
  try {
    return fs
      .readdirSync(directory, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => ({ name: entry.name, layer }));
  } catch {
    return [];
  }
}

function listPersistentPlugins() {
  const home = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
  const profileDir = path.join(home, "profiles", "web");
  const byId = new Map();
  for (const plugin of readPatchPlugins(
    path.join(profileDir, "cordis.patch.yml"),
    "profile",
  )) {
    byId.set(plugin.id, plugin);
  }
  for (const plugin of readPatchPlugins(
    path.join(home, "cordis.patch.yml"),
    "home",
  )) {
    byId.set(plugin.id, plugin);
  }
  return JSON.stringify(
    {
      mode: "persistent-plugins",
      note:
        "This lists installed host/profile plugins. cordis_inspect_self only lists temporary dynamic plugins created in the current session.",
      bundles: readProfileBundles(profileDir),
      plugins: [...byId.values()],
      localPluginDirectories: [
        ...readPluginDirectories(path.join(profileDir, "plugins"), "profile"),
        ...readPluginDirectories(path.join(home, "plugins"), "home"),
      ],
    },
    null,
    2,
  );
}

const persistentPluginListTool = defineTool({
  name: "plugin_list",
  description:
    "List persistent DSH host/profile plugins and built-in profile bundles. Use this when the user asks which plugins are installed. Do not use cordis_inspect_self for that question because it only lists temporary dynamic plugins in the current session.",
  parameters: {},
  output: {
    schema: { type: "string" },
    render(_args, value) {
      return [{ type: "text", text: value }];
    },
  },
  async execute() {
    return listPersistentPlugins();
  },
});

function readConfig() {
  const home = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
  try {
    const parsed = JSON.parse(
      fs.readFileSync(path.join(home, "shiyi-free-search.json"), "utf8"),
    );
    return {
      provider: PROVIDERS.has(parsed.provider)
        ? parsed.provider
        : DEFAULT_CONFIG.provider,
      region:
        typeof parsed.region === "string" && parsed.region
          ? parsed.region
          : DEFAULT_CONFIG.region,
      bingMarket:
        typeof parsed.bingMarket === "string" && parsed.bingMarket
          ? parsed.bingMarket
          : DEFAULT_CONFIG.bingMarket,
    };
  } catch {
    return DEFAULT_CONFIG;
  }
}

function decodeEntities(value) {
  return String(value ?? "")
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)));
}

function stripTags(value) {
  return decodeEntities(value)
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function uniqueSources(sources, limit) {
  const seen = new Set();
  const output = [];
  for (const source of sources) {
    if (!source.url || seen.has(source.url)) continue;
    seen.add(source.url);
    output.push(source);
    if (output.length >= limit) break;
  }
  return output;
}

function childSignal(parent, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const abort = () => controller.abort();
  parent?.addEventListener("abort", abort);
  return {
    signal: controller.signal,
    dispose() {
      clearTimeout(timer);
      parent?.removeEventListener("abort", abort);
    },
  };
}

async function fetchText(url, signal, accept = "text/html") {
  const scoped = childSignal(signal, 12000);
  try {
    const response = await fetch(url, {
      headers: {
        accept,
        "accept-language": ACCEPT_LANGUAGE,
        "user-agent": USER_AGENT,
      },
      redirect: "follow",
      signal: scoped.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.text();
  } finally {
    scoped.dispose();
  }
}

function extractDdgUrl(raw) {
  if (!raw) return null;
  const match = raw.match(/[?&]uddg=([^&]+)/);
  if (match) {
    try {
      return decodeURIComponent(match[1]);
    } catch {
      return match[1];
    }
  }
  if (raw.startsWith("//")) return `https:${raw}`;
  return raw.startsWith("http") ? raw : null;
}

async function searchBing(query, maxResults, config, signal) {
  const params = new URLSearchParams({
    q: query,
    format: "rss",
    mkt: config.bingMarket ?? "zh-CN",
  });
  const xml = await fetchText(
    `https://www.bing.com/search?${params}`,
    signal,
    "application/rss+xml,text/xml",
  );
  const items = xml.match(/<item>[\s\S]*?<\/item>/gi) ?? [];
  const sources = items.map((item) => {
    const read = (tag) =>
      item.match(new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`, "i"))?.[1];
    const url = stripTags(read("link"));
    return {
      url,
      title: stripTags(read("title")),
      snippet: stripTags(read("description")),
      publishedAt: stripTags(read("pubDate")),
    };
  });
  return {
    sources: uniqueSources(sources, maxResults ?? 10),
    truncated: false,
  };
}

async function searchDdgHtml(query, maxResults, config, signal) {
  const params = new URLSearchParams({ q: query });
  if (config.region) params.set("kl", config.region);
  const html = await fetchText(
    `https://html.duckduckgo.com/html/?${params}`,
    signal,
  );
  if (/anomaly|captcha|unusual traffic|robot check/i.test(html.slice(0, 5000))) {
    throw new Error("DuckDuckGo rate limited the request");
  }
  const blocks =
    html.match(
      /<div class="result results_links[\s\S]*?<\/div>\s*<\/div>\s*<\/div>/g,
    ) ?? [];
  const sources = [];
  for (const block of blocks) {
    const href = block.match(
      /<a[^>]*class="result__a"[^>]*href="([^"]*)"/,
    )?.[1];
    const url = extractDdgUrl(href);
    if (!url) continue;
    sources.push({
      url,
      title: stripTags(
        block.match(/<a[^>]*class="result__a"[^>]*>(.*?)<\/a>/)?.[1],
      ),
      snippet: stripTags(
        block.match(
          /<a[^>]*class="result__snippet"[^>]*>(.*?)<\/a>/,
        )?.[1],
      ),
    });
  }
  return {
    sources: uniqueSources(sources, maxResults ?? 10),
    truncated: false,
  };
}

async function searchDdgLite(query, maxResults, signal) {
  const params = new URLSearchParams({ q: query });
  const html = await fetchText(
    `https://lite.duckduckgo.com/lite/?${params}`,
    signal,
  );
  const links =
    html.match(/<a[^>]*class=['"]result-link['"][^>]*>[\s\S]*?<\/a>/g) ??
    [];
  const snippets =
    html.match(/class=['"]result-snippet['"][^>]*>([\s\S]*?)<\/td>/g) ??
    [];
  const sources = [];
  for (let i = 0; i < links.length; i += 1) {
    const href = links[i].match(/href="([^"]*)"/)?.[1];
    const url = extractDdgUrl(href);
    if (!url) continue;
    sources.push({
      url,
      title: stripTags(links[i]),
      snippet: stripTags(snippets[i]),
    });
  }
  return {
    sources: uniqueSources(sources, maxResults ?? 10),
    truncated: false,
  };
}

async function searchDeepSeek(query, maxResults, apiKey, signal) {
  if (!apiKey) throw new Error("DeepSeek search API key is not configured");
  const scoped = childSignal(signal, 30000);
  try {
    const response = await fetch(
      "https://api.deepseek.com/anthropic/v1/messages",
      {
        method: "POST",
        headers: {
          "x-api-key": apiKey,
          authorization: `Bearer ${apiKey}`,
          "anthropic-version": "2023-06-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          model: "deepseek-v4-flash",
          max_tokens: 4096,
          messages: [
            {
              role: "user",
              content: [
                {
                  type: "text",
                  text: `Perform a web search for: ${query}`,
                },
              ],
            },
          ],
          tools: [
            { type: "web_search_20250305", name: "web_search", max_uses: 1 },
          ],
        }),
        signal: scoped.signal,
      },
    );
    if (!response.ok) throw new Error(`DeepSeek HTTP ${response.status}`);
    const data = await response.json();
    const sources = [];
    for (const block of data.content ?? []) {
      if (block.type !== "web_search_tool_result") continue;
      for (const item of block.content ?? []) {
        if (item.type !== "web_search_result" || !item.url) continue;
        sources.push({
          url: item.url,
          title: item.title ?? "",
          snippet: item.snippet ?? "",
          publishedAt: item.page_age ?? "",
        });
      }
    }
    return {
      sources: uniqueSources(sources, maxResults ?? 10),
      truncated: false,
    };
  } finally {
    scoped.dispose();
  }
}

const name = "shiyi-free-search";
const inject = ["web", "tools"];

function apply(ctx) {
  const credentials = ctx.get("credentials");

  ctx.tools.register(persistentPluginListTool);

  ctx.web.registerSearchProvider({
    id: "shiyi-free",
    available() {
      return true;
    },
    async search(request, signal) {
      const config = readConfig();
      const selected = config.provider ?? "auto";
      if (selected === "deepseek") {
        let apiKey = "";
        try {
          apiKey =
            (await credentials?.resolve("SHIYI_DSH_SEARCH_KEY"))?.value ?? "";
        } catch {}
        return searchDeepSeek(
          request.query,
          request.maxResults,
          apiKey,
          signal,
        );
      }

      const order =
        selected === "bing"
          ? ["bing", "ddg", "ddg-lite"]
          : selected === "ddg"
            ? ["ddg", "bing", "ddg-lite"]
            : selected === "ddg-lite"
              ? ["ddg-lite", "bing", "ddg"]
              : ["bing", "ddg", "ddg-lite"];
      let lastError;
      for (const engine of order) {
        try {
          const result =
            engine === "bing"
              ? await searchBing(
                  request.query,
                  request.maxResults,
                  config,
                  signal,
                )
              : engine === "ddg"
                ? await searchDdgHtml(
                    request.query,
                    request.maxResults,
                    config,
                    signal,
                  )
                : await searchDdgLite(
                    request.query,
                    request.maxResults,
                    signal,
                  );
          if (result.sources.length > 0) return result;
          lastError = new Error(`${engine} returned no results`);
        } catch (error) {
          lastError = error;
          ctx.logger.warn(
            `shiyi-free-search: ${engine} failed: ${error?.message ?? error}`,
          );
        }
      }
      throw lastError ?? new Error("all search engines failed");
    },
  });
}

export { apply, inject, name };
