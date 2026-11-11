import fs from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"

const schemePattern = /^[A-Za-z][A-Za-z0-9+.-]*:/

// Resolve URLs against the canonical no-slash page path. Netlify serves the same
// HTML at slash and no-slash URLs, so emitted URLs must not depend on the request path.
export function normalizeUrl(value, pagePath) {
	if (
		value === "" ||
		value.startsWith("#") ||
		value.startsWith("//") ||
		schemePattern.test(value)
	) {
		return value
	}

	const resolved = new URL(value, `https://site.invalid${pagePath}`)
	const pathname = resolved.pathname.replace(/\/+$/, "") || "/"
	return `${pathname}${resolved.search}${resolved.hash}`
}

export function normalizeHtml(html, pagePath) {
	return html.replace(/(?<![\w:-])(href|src)="([^"]*)"/g, (match, attribute, value) => {
		const normalized = normalizeUrl(value, pagePath)
		return normalized === value ? match : `${attribute}="${normalized}"`
	})
}

function walk(directory) {
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const entryPath = path.join(directory, entry.name)
		return entry.isDirectory() ? walk(entryPath) : [entryPath]
	})
}

function pagePathForHtml(relativePath) {
	const posixPath = relativePath.split(path.sep).join("/")
	if (posixPath === "index.html") return "/"
	if (posixPath.endsWith("/index.html")) {
		return `/${posixPath.slice(0, -"/index.html".length)}`
	}
	return `/${posixPath.slice(0, -".html".length)}`
}

function main() {
	const wwwArgument = process.argv[2]
	if (!wwwArgument) {
		throw new Error("Usage: node postprocess.mjs WWW_DIR")
	}
	const wwwDir = path.resolve(wwwArgument)
	const htmlFiles = walk(wwwDir).filter((file) => file.endsWith(".html"))
	let changedFiles = 0

	for (const file of htmlFiles) {
		const original = fs.readFileSync(file, "utf8")
		const pagePath = pagePathForHtml(path.relative(wwwDir, file))
		const normalized = normalizeHtml(original, pagePath)
		if (normalized !== original) {
			fs.writeFileSync(file, normalized)
			changedFiles += 1
		}
	}

	console.log(`HTML URL normalization: ${changedFiles} of ${htmlFiles.length} pages updated.`)
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
	main()
}
