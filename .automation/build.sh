#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

# Date-only frontmatter must have the same meaning on every build host.
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUARTZ_DIR="$SCRIPT_DIR/quartz"
OVERLAY_DIR="$SCRIPT_DIR/overlay"
PATCH_DIR="$SCRIPT_DIR/patches"
BUILD_DIR="$SCRIPT_DIR/build"
WWW_DIR="$SCRIPT_DIR/www"
TEMP_DIR=""

cleanup() {
	if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
		rm -rf "$TEMP_DIR"
	fi
}
trap cleanup EXIT

usage() {
	cat <<'EOF'
Usage: ./.automation/build.sh [build|serve|clean|check|update [tag]]

  build          Create a fresh build environment and build the site (default).
  serve          Create a fresh build environment and start Quartz's server.
  clean          Remove the build environment and generated site.
  check          Test all customization patches without changing the build.
  update [tag]   Update Quartz to a tag, or the latest stable tag, then check.
EOF
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

for required_command in npm node gawk git patch tar; do
	if ! command -v "$required_command" >/dev/null 2>&1; then
		fail "Could not find $required_command in your system's PATH."
	fi
done

[[ -d "$OVERLAY_DIR" ]] || fail "Could not locate $OVERLAY_DIR."
[[ -d "$QUARTZ_DIR" ]] || fail "Could not locate $QUARTZ_DIR."
[[ -d "$PATCH_DIR" ]] || fail "Could not locate $PATCH_DIR."
git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 ||
	fail "Could not locate the website git repository."

json_version() {
	node -e 'const fs = require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version)' "$1"
}

quartz_commit() {
	git -C "$QUARTZ_DIR" rev-parse HEAD
}

quartz_description() {
	git -C "$QUARTZ_DIR" describe --tags --always HEAD
}

patch_header() {
	local patch_file="$1"
	local key="$2"
	sed -n "s/^# $key: //p" "$patch_file" | head -n 1
}

validate_overlay() {
	local unexpected_files
	unexpected_files="$(find "$OVERLAY_DIR" -type f \
		! -path "$OVERLAY_DIR/quartz.config.yaml" \
		! -path "$OVERLAY_DIR/quartz/styles/custom.scss" \
		! -path "$OVERLAY_DIR/quartz/static/*" -print)"
	if [[ -n "$unexpected_files" ]]; then
		printf 'Unexpected overlay files:\n%s\n' "$unexpected_files" >&2
		fail "Move source and dependency changes to $PATCH_DIR."
	fi
}

copy_quartz() {
	local destination="$1"
	mkdir -p "$destination"
	# Archive tracked files so untracked files in the submodule cannot enter a build.
	git -C "$QUARTZ_DIR" archive HEAD | tar -x -C "$destination"
}

copy_overlay() {
	local destination="$1"
	validate_overlay
	cp "$OVERLAY_DIR/quartz.config.yaml" "$destination/quartz.config.yaml"
	cp "$OVERLAY_DIR/quartz/styles/custom.scss" "$destination/quartz/styles/custom.scss"
	cp -a "$OVERLAY_DIR/quartz/static/." "$destination/quartz/static/"
}

prepare_environment() {
	local destination="$1"
	copy_quartz "$destination"
	copy_overlay "$destination"
	(
		cd "$destination"
		npm ci
	)
}

check_patches() {
	local destination="$1"
	local actual_quartz
	local patch_files=("$PATCH_DIR"/*.patch)
	local failures=0
	actual_quartz="$(json_version "$destination/package.json")"

	[[ ${#patch_files[@]} -gt 0 ]] || fail "No customization patches were found."

	for patch_file in "${patch_files[@]}"; do
		local patch_name expected_quartz package_name expected_package actual_package
		local drifted=0
		patch_name="$(basename "$patch_file")"
		expected_quartz="$(patch_header "$patch_file" quartz-version)"
		package_name="$(patch_header "$patch_file" package)"
		expected_package="$(patch_header "$patch_file" package-version)"

		if [[ -n "$expected_quartz" && "$expected_quartz" != "$actual_quartz" ]]; then
			printf 'VERSION %s: patch reviewed for Quartz %s, installed Quartz is %s.\n' \
				"$patch_name" "$expected_quartz" "$actual_quartz"
			drifted=1
		fi

		if [[ -n "$package_name" ]]; then
			actual_package="not installed"
			if [[ -f "$destination/node_modules/$package_name/package.json" ]]; then
				actual_package="$(json_version "$destination/node_modules/$package_name/package.json")"
			fi
			if [[ "$expected_package" != "$actual_package" ]]; then
				printf 'VERSION %s: patch reviewed for %s %s, installed version is %s.\n' \
					"$patch_name" "$package_name" "$expected_package" "$actual_package"
				drifted=1
			fi
		fi

		if patch -p1 -d "$destination" --forward --batch --no-backup-if-mismatch \
			--dry-run <"$patch_file"; then
			if [[ "$drifted" -eq 0 ]]; then
				printf 'PASS %s\n' "$patch_name"
			else
				printf 'REVIEW %s: the patch applies, but its version metadata needs review.\n' \
					"$patch_name"
				failures=$((failures + 1))
			fi
		else
			printf 'DRIFT %s: the patch does not apply cleanly.\n' "$patch_name" >&2
			failures=$((failures + 1))
		fi
	done

	if [[ "$failures" -gt 0 ]]; then
		printf 'Patch result: %s patch(es) require reintegration or version review.\n' \
			"$failures" >&2
		return 1
	fi
}

apply_patches() {
	local destination="$1"
	local patch_files=("$PATCH_DIR"/*.patch)
	local patch_file
	for patch_file in "${patch_files[@]}"; do
		if ! patch -p1 -d "$destination" --forward --batch --no-backup-if-mismatch \
			<"$patch_file"; then
			fail "Could not apply $(basename "$patch_file"). The build was not started."
		fi
	done
}

run_doctor() {
	local destination="$1"
	(
		cd "$destination"
		npx --no-install quartz plugin doctor
	)
}

check_customizations() {
	printf 'Quartz customization check\n'
	printf '  commit: %s\n' "$(quartz_commit)"
	printf '  ref: %s\n' "$(quartz_description)"
	printf '  package: %s\n' "$(json_version "$QUARTZ_DIR/package.json")"

	TEMP_DIR="$(mktemp -d "$SCRIPT_DIR/.check.XXXXXX")"
	prepare_environment "$TEMP_DIR"

	local failed=0
	check_patches "$TEMP_DIR" || failed=1
	run_doctor "$TEMP_DIR" || failed=1

	if [[ "$failed" -ne 0 ]]; then
		printf 'Result: NOT READY. Review each DRIFT or REVIEW entry above.\n' >&2
		return 1
	fi
	printf 'Result: READY. All patches apply to the reviewed Quartz and package versions.\n'
}

prepare_content() {
	rm -rf "$BUILD_DIR/content"
	mkdir "$BUILD_DIR/content"
	tar -cf - -C "$REPO_ROOT" --exclude='.automation' . | tar -xf - -C "$BUILD_DIR/content"
	(
		cd "$BUILD_DIR/content"
		rm -rf .git \
			.github \
			.gitignore \
			.obsidian \
			.trash \
			.vscode \
			private \
			README.md
		find . -type f \( -name '.DS_Store' -o -name '.nomedia' \) -delete
		find . -type f -iname '*.md' -exec gawk -i inplace '{ _ = 0 }; \
			match($0, /(.*)!\[([^\]]+)\]\(([^:\)]+)\)(.*)/, u) { \
				_ = 1; \
				gsub("%20", " ", u[3]); \
				printf("%s![[%s|%s]]%s\n", u[1], u[3], u[2], u[4]) \
			}; !_ { print $0 }' "{}" \;
	)
}

build_site() {
	local serve="$1"
	rm -rf "$BUILD_DIR"
	prepare_environment "$BUILD_DIR"
	if ! check_patches "$BUILD_DIR"; then
		fail "Customization checks failed. Run ./.automation/build.sh check for details."
	fi
	apply_patches "$BUILD_DIR"
	run_doctor "$BUILD_DIR"
	prepare_content

	rm -rf "$WWW_DIR"
	mkdir -p "$WWW_DIR"
	(
		cd "$BUILD_DIR"
		if [[ "$serve" == "true" ]]; then
			npx --no-install quartz build --output ../www --serve
		else
			npx --no-install quartz build --output ../www
		fi
	)
	node --test "$SCRIPT_DIR/postprocess.test.mjs"
	node "$SCRIPT_DIR/postprocess.mjs" "$WWW_DIR"
	node "$SCRIPT_DIR/smoke-test.mjs" "$BUILD_DIR" "$WWW_DIR"
}

update_quartz() {
	local requested_tag="${1:-}"
	local current_commit target_tag target_commit target_version latest_tag
	current_commit="$(quartz_commit)"

	if [[ -n "$(git -C "$QUARTZ_DIR" status --porcelain --untracked-files=no)" ]]; then
		fail "The Quartz submodule has tracked changes. Commit or remove them before updating."
	fi

	printf 'Fetching Quartz release tags...\n'
	git -C "$QUARTZ_DIR" fetch --tags origin
	if [[ -n "$requested_tag" ]]; then
		target_tag="$requested_tag"
	else
		latest_tag="$(git -C "$QUARTZ_DIR" tag --list 'v*' |
			grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
		[[ -n "$latest_tag" ]] || fail "No stable Quartz release tags were found."
		target_tag="$latest_tag"
	fi

	target_commit="$(git -C "$QUARTZ_DIR" rev-parse --verify "$target_tag^{commit}")" ||
		fail "Could not resolve Quartz tag $target_tag."
	target_version="$(git -C "$QUARTZ_DIR" show "$target_tag:package.json" |
		node -e 'const fs = require("fs"); console.log(JSON.parse(fs.readFileSync(0, "utf8")).version)')"

	printf 'Quartz update\n'
	printf '  previous: %s (%s)\n' "$current_commit" "$(quartz_description)"
	printf '  target: %s %s (package %s)\n' "$target_tag" "$target_commit" "$target_version"

	if [[ "$current_commit" == "$target_commit" ]]; then
		printf 'Quartz already uses the target release.\n'
	else
		git -C "$QUARTZ_DIR" checkout --detach "$target_commit"
	fi

	if check_customizations; then
		printf 'Update result: READY. The submodule is at %s; review and stage its new commit.\n' \
			"$target_tag"
	else
		printf 'Update result: NOT READY. The submodule remains at %s %s.\n' \
			"$target_tag" "$target_commit" >&2
		printf 'Next: rebase each DRIFT patch, review each VERSION entry, update patch metadata, then rerun check.\n' >&2
		return 1
	fi
}

command="${1:-build}"
case "$command" in
build)
	[[ $# -le 1 ]] || fail "The build command takes no arguments."
	build_site false
	;;
serve)
	[[ $# -le 1 ]] || fail "The serve command takes no arguments."
	build_site true
	;;
clean)
	[[ $# -le 1 ]] || fail "The clean command takes no arguments."
	rm -rf "$BUILD_DIR" "$WWW_DIR"
	;;
check)
	[[ $# -le 1 ]] || fail "The check command takes no arguments."
	check_customizations
	;;
update)
	[[ $# -le 2 ]] || fail "The update command accepts at most one tag."
	update_quartz "${2:-}"
	;;
help | -h | --help)
	usage
	;;
*)
	usage >&2
	fail "Unknown command: $command"
	;;
esac
