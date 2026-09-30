# When images are rebuilt

Wrappers check their image each time they run. They rebuild it, or pull a fresh copy of an official image, when:

- **The image is missing.** This happens on the first run, or after it was removed.
- **The wrapper script changed** since the image was built, for example after `bulkhead update` brought in a new version. This applies only to wrappers that build their own image.
- **The image is too old.** This applies to wrappers that install the tool's latest release, which rebuild on a fixed schedule (weekly today).
- **A newer base or official image was published** on Docker Hub. The check runs at most once a day. If Docker Hub can't be reached, the current image is kept.
- **You run `<wrapper> update`.** This removes the image, and the next run rebuilds or pulls it.

Nothing else triggers a rebuild. `bulkhead update` only updates the scripts, and images change on their next run. Where a wrapper pins a version (of the tool, its base image or an official image), moving to a newer one means editing the wrapper script. The next run then builds or pulls the new version.

## Updating a tool on demand

Some wrappers accept `update`, which replaces their image with the tool's latest release on the next run. To pass the word `update` to the tool itself instead, put it after `--`:

```bash
<wrapper> update      # replace the image
<wrapper> -- update   # run the tool's own update
```
