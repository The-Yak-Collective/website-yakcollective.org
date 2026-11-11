import fs from "node:fs"
import path from "node:path"
import { createRequire } from "node:module"
import { pathToFileURL } from "node:url"

const [buildArgument, wwwArgument] = process.argv.slice(2)
if (!buildArgument || !wwwArgument) {
	throw new Error("Usage: node smoke-test.mjs BUILD_DIR WWW_DIR")
}
const buildDir = path.resolve(buildArgument)
const wwwDir = path.resolve(wwwArgument)

let failures = 0
function check(condition, message) {
	if (!condition) {
		console.error(`FAIL ${message}`)
		failures += 1
	}
}

function walk(directory) {
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const entryPath = path.join(directory, entry.name)
		return entry.isDirectory() ? walk(entryPath) : [entryPath]
	})
}

function frontmatter(markdownPath) {
	const source = fs.readFileSync(markdownPath, "utf8")
	if (!source.startsWith("---")) return ""
	return source.split(/^---\s*$/m)[1] ?? ""
}

const contentDir = path.join(buildDir, "content")
const markdownFiles = walk(contentDir).filter((file) => file.endsWith(".md"))
const htmlFiles = walk(wwwDir).filter((file) => file.endsWith(".html"))
const datedFiles = markdownFiles.filter((file) => /^date:\s*\S+/m.test(frontmatter(file)))

check(markdownFiles.length > 0, "the copied vault contains Markdown files")
check(htmlFiles.length >= markdownFiles.length, "every Markdown file has an HTML page")
for (const requiredFile of ["index.html", "404.html", "index.xml", "sitemap.xml"]) {
	check(fs.existsSync(path.join(wwwDir, requiredFile)), `${requiredFile} was emitted`)
}

const rss = fs.readFileSync(path.join(wwwDir, "index.xml"), "utf8")
const rssItems = rss.match(/<item>/g)?.length ?? 0
check(rssItems === datedFiles.length, `RSS has ${rssItems} items; expected ${datedFiles.length} dated pages`)
check(!rss.includes("<title>Welcome!</title>"), "RSS excludes undated pages")
check(!rss.includes("https://www.yakcollective.org/./"), "RSS links contain no /./ segments")
check(!/(?:href|src)=&quot;\.\.?\//.test(rss), "RSS links and images use absolute URLs")

for (const file of datedFiles) {
	const dateMatch = frontmatter(file).match(/^\s*date:\s*["']?(\d{4}-\d{2}-\d{2})["']?\s*$/m)
	if (!dateMatch) continue
	const expectedDate = new Date(`${dateMatch[1]}T00:00:00Z`).toUTCString()
	check(
		rss.includes(`<pubDate>${expectedDate}</pubDate>`),
		`${path.relative(contentDir, file)} uses midnight UTC in RSS`,
	)
}

const sitemap = fs.readFileSync(path.join(wwwDir, "sitemap.xml"), "utf8")
const sitemapUrls = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1])
check(sitemapUrls.includes("https://www.yakcollective.org/"), "the sitemap root has one trailing slash")
check(
	sitemapUrls.filter((url) => url !== "https://www.yakcollective.org/").every((url) => !url.endsWith("/")),
	"non-root sitemap URLs have no trailing slash",
)
check(sitemapUrls.every((url) => !url.includes("/./")), "sitemap URLs contain no /./ segments")

const contentIndex = JSON.parse(fs.readFileSync(path.join(wwwDir, "static/contentIndex.json"), "utf8"))
check(
	!Object.values(contentIndex).some((entry) => Object.hasOwn(entry, "frontmatterDate")),
	"frontmatterDate is internal to RSS generation",
)

let timeCount = 0
for (const file of htmlFiles) {
	const html = fs.readFileSync(file, "utf8")
	const title = html.match(/<title>([^<]*)<\/title>/)
	check(title && !title[1].includes(" :: The Yak Collective"), `${path.relative(wwwDir, file)} has no browser title suffix`)
	for (const match of html.matchAll(/<time\s+datetime="([^"]+)"[^>]*>([^<]+)<\/time>/g)) {
		timeCount += 1
		const expected = new Date(match[1]).toLocaleDateString("en-US", {
			weekday: "long",
			year: "numeric",
			month: "long",
			day: "numeric",
			timeZone: "UTC",
		})
		check(match[2] === expected, `${path.relative(wwwDir, file)} renders a long UTC date`)
	}
}
check(timeCount > 0, "pages contain formatted dates")

const require = createRequire(path.join(buildDir, "package.json"))
const importBuildModule = async (specifier) =>
	import(pathToFileURL(require.resolve(specifier)).href)
const { h } = await importBuildModule("preact")
const render = (await importBuildModule("preact-render-to-string")).default
const importFile = async (relativePath) =>
	import(pathToFileURL(path.join(buildDir, relativePath)).href)

for (const modulePath of [
	"node_modules/@quartz-community/utils/dist/index.js",
	"node_modules/@quartz-community/utils/dist/path.js",
]) {
	const { resolveRelative } = await importFile(modulePath)
	check(
		resolveRelative("newsletters/example", "newsletters") === "../newsletters",
		`${modulePath} removes trailing slashes`,
	)
}

const { Breadcrumbs } = await importFile(
	"node_modules/@quartz-community/breadcrumbs/dist/components/index.js",
)
const BreadcrumbComponent = Breadcrumbs({ rootName: "The Yak Collective", spacerSymbol: "/" })
const breadcrumbHtml = render(
	h(BreadcrumbComponent, { fileData: { slug: "virtual" }, allFiles: [], ctx: {} }),
)
check(breadcrumbHtml.includes("The Yak Collective"), "the breadcrumb fallback renders its root")
check(breadcrumbHtml.includes("virtual"), "the breadcrumb fallback renders a missing trie path")
check(breadcrumbHtml.includes('href="."'), "a top-level fallback links its root to the site root")

const ofm = fs.readFileSync(
	path.join(buildDir, "node_modules/@quartz-community/obsidian-flavored-markdown/dist/index.js"),
	"utf8",
)
check(ofm.includes('important: "important"'), "important callouts remain distinct from tips")
check(ofm.includes('caution: "caution"'), "caution callouts remain distinct from warnings")

if (failures > 0) {
	console.error(`Output smoke test: ${failures} failure(s).`)
	process.exit(1)
}
console.log(
	`Output smoke test: PASS (${markdownFiles.length} notes, ${htmlFiles.length} HTML pages, ${rssItems} dated RSS items).`,
)
