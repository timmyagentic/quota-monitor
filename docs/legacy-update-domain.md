# Legacy update domain

Keep `quota-monitor.timmyagentic.com` attached to the same `quota-monitor-site` Worker as `quota-monitor.timmyagentic.si`. Installed clients through 1.0.13-beta.1 contain the old private Beta feed and enrollment URL. They cannot discover the new feed while the old hostname is unavailable.

Serve authenticated API responses directly on both hosts; do not replace the old private Beta API with a cross-origin redirect. Both hosts share the existing device authorization, D1 and R2 resources. Keep new app builds, feed enclosure URLs and canonical website URLs on `.si`. Public stable updates remain on GitHub.

## Retirement gate

There is no scheduled expiry. Remove the compatibility hostname only after all remaining supported clients are confirmed migrated to a build containing the new endpoints. A quiet traffic window, downloaded package, or device last-seen timestamp alone does not prove installation, especially for offline clients. Keep the alias when migration cannot be established. A future retirement requires an explicit migration review and authorization.

## Verification

Verify valid HTTPS and authenticated feed 200 on both hosts with matching bytes; anonymous and invalid-token requests must remain 404. Read each advertised artifact and release note, verify the signed package checksum, and verify Range 206. Check old enrollment routing without consuming a valid enrollment code. Do not claim an actual client installation from HTTP checks alone.
