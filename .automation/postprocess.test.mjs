import test from "node:test"
import assert from "node:assert/strict"
import { normalizeHtml, normalizeUrl } from "./postprocess.mjs"

const cases = [
	["../study-groups/", "/study-groups/fermi-gym", "/study-groups"],
	["../newsletters/#top", "/newsletters/2023-06-30-archetypes", "/newsletters#top"],
	["./study-groups/?a=1#b", "/", "/study-groups?a=1#b"],
	["../../", "/projects/astonishing-stories/x", "/"],
	["./", "/about", "/"],
	[".././../assets/a.webp", "/projects/astonishing-stories", "/assets/a.webp"],
	[".././assets/a.webp", "/study-groups/fermi-gym", "/assets/a.webp"],
	["/already/", "/about", "/already"],
	["#fragment", "/about", "#fragment"],
	["mailto:a@example.com", "/about", "mailto:a@example.com"],
	["https://example.com/x/", "/about", "https://example.com/x/"],
	["//cdn.example.com/x/", "/about", "//cdn.example.com/x/"],
	["data:image/png;base64,abcd", "/about", "data:image/png;base64,abcd"],
	["", "/about", ""],
]

for (const [value, pagePath, expected] of cases) {
	test(`normalize ${value || "an empty URL"} from ${pagePath}`, () => {
		assert.equal(normalizeUrl(value, pagePath), expected)
	})
}

test("HTML normalization handles attributes without rewriting lookalikes", () => {
	const input =
		'<a href="../study-groups/">Study</a><img src="../assets/a.png"><a data-href="../ignored">X</a><svg xlink:href="#icon"></svg><a href="#top">Top</a>'
	const expected =
		'<a href="/study-groups">Study</a><img src="/assets/a.png"><a data-href="../ignored">X</a><svg xlink:href="#icon"></svg><a href="#top">Top</a>'
	assert.equal(normalizeHtml(input, "/study-groups/fermi-gym"), expected)
})

test("HTML normalization is idempotent", () => {
	const input = '<a href="../study-groups/">Study</a><img src="../assets/a.png">'
	const once = normalizeHtml(input, "/study-groups/fermi-gym")
	assert.equal(normalizeHtml(once, "/study-groups/fermi-gym"), once)
})
