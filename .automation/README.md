# Website automation

Run `./.automation/build.sh` from the repository root to build the site in `.automation/www`. The build uses a fresh copy of the Quartz submodule. It installs dependencies with `npm ci`, applies the site overlay and patches, and checks the plugin configuration. It also makes HTML URLs root-relative so pages work with or without a trailing slash in the request URL. Output smoke tests check these URLs and the site customizations. Run `./.automation/build.sh clean` to remove `.automation/build` and `.automation/www`.

Run `./.automation/build.sh check` to test the customizations without changing the existing build. The command checks patch context and the Quartz or package version in each patch header. A `DRIFT` result means that a patch does not apply. A `REVIEW` result means that the patch applies but its version metadata needs review. Both results block a build until someone resolves them.

Run `./.automation/build.sh update` to update the submodule to the latest stable Quartz tag and run the customization checks. Run `./.automation/build.sh update v5.1.0` to select a tag. The update command leaves the submodule at the target tag when checks fail. This lets a maintainer rebase patches against the new release. It does not commit the submodule change.

The overlay contains only site-owned configuration, SCSS, and static assets. Source and dependency changes live in numbered files under `.automation/patches`. Each patch states its purpose, target, reviewed version, and reintegration notes. Keep these headers current after reviewing a Quartz update.

After a Quartz update, review every `DRIFT` and `REVIEW` line in the update output. Rebase failed patches against the installed source. Check whether upstream now provides the intended behavior before keeping a patch. Update the version header after reviewing a patch that still applies. Run `./.automation/build.sh check`, then run a full build to test the generated site.
