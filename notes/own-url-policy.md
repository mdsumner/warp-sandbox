# Own URLs: a policy for warping data the catalogue doesn't list

*Draft, 2026-11-08. Nothing here is built yet. Decisions for the maintainer
are marked **Decide**.*

## Where things stand

Today the sandbox warps only catalogue sources. The `vrt=` option changes how
a catalogue source is read (`bands`, `ot`, `scale`, ...), never which file is
opened. The service listens on 127.0.0.1:8090, and the only way in is an SSH
tunnel, so its one user is the person who can log in anyway.

An own-URL feature (a `url=` parameter, a field on the page) changes that in
one important way: **GDAL would open a string the user chose.** A GDAL "dataset
name" is not just a URL. It can name a local file, a `/vsis3/` bucket read with
the server's keys, a VRT that pulls in other files, a WMS description pointing
anywhere, or a memory address (`MEM:::DATAPOINTER=`). So the policy is mostly
about never handing GDAL the user's string as it is.

## What could go wrong

| risk | how | why it matters here |
|---|---|---|
| Reading local files | a path, `/vsizip/` of a local file, or a VRT whose `SourceFilename` is local | the volume holds every user's home directory |
| Using the server's credentials | `/vsis3/`, `/vsigs/`, `/vsiaz/`; `.netrc`; cookies | the service runs with `~/.Renviron`, which carries Pawsey, source.coop and Acacia keys, Earthdata auth, API keys and GitHub tokens; `~/.aws/credentials` exists |
| Reaching internal addresses (SSRF) | `http://169.254.169.254/...`, `127.0.0.1:<port>`, private ranges, or a public URL that redirects there | the OpenStack metadata service hands out the VM's user-data (the recipes' launch scripts); RStudio and other services listen locally |
| Driver surprises | drivers with side effects or large attack surface (VRT pixel functions, raw raster bands, HDF5 external links, database connection strings) | each is a way to do more than read pixels |
| Exhaustion | a 100,000² raster with no overviews, thousands of tiles, slow servers | the VM is shared with ecostats users |
| Cost and abuse | the sandbox as a free proxy or a scanner | outbound traffic is billed to the allocation's reputation, if not its budget |

## Rules (whatever the tier)

1. **Accept a URL, not a GDAL string.** Parse it as a URL. Accept only `https://`
   (**Decide:** `http://` too?), with no credentials in it (`user:pass@`). Build
   the DSN ourselves: `/vsicurl/` plus the URL. Reject anything containing `/vsi`,
   a driver prefix (`XYZ:`), `<`, or a newline.
2. **One driver: GTiff.** That covers COGs and plain GeoTIFFs. Every engine must
   open the URL with that driver only:
   - `GDAL7::gdal_open(drivers = "GTiff")`
   - `gdalwarp -if GTiff`
   - `gdal raster reproject --input-format GTiff`

   gdalraster's `GDALRaster` can't restrict drivers, so for own URLs the rwarp
   engine reads through GDAL7. (**Decide:** add Zarr later? It's a second driver
   with its own attack surface.) Setting `CPL_VSIL_CURL_ALLOWED_EXTENSIONS=.tif,.tiff`
   for these reads is a cheap second layer, but it's process-wide, so it needs care
   alongside catalogue sources (VRTs).
3. **No credentials.** Own-URL reads run with `AWS_NO_SIGN_REQUEST=YES`, no
   `.netrc` (`GDAL_HTTP_NETRC=NO`), no cookie file, and no `AWS_*`, `GS_*` or
   `AZURE_*` settings. Before any tier beyond the tunnel, run the service as a
   dedicated user with an empty home and no `.Renviron`, so a mistake elsewhere
   can't reach your keys either.
4. **No internal addresses.** Resolve the host and refuse loopback, link-local
   (169.254.0.0/16, including the metadata service), private (10/8, 172.16/12,
   192.168/16), CGNAT (100.64/10) and IPv6 equivalents. Redirects bypass a
   check done once, so either stop GDAL following redirects for these reads (to
   be checked: which `GDAL_HTTP_*` option does that) or, better, back it with an
   egress firewall rule for the service's user (`iptables -m owner --uid-owner`).
   A firewall rule holds even when GDAL behaves unexpectedly.
5. **Probe before warping.** Open the header (the catalogue's `probe_one()`),
   then apply the same limits as catalogue sources: `MAX_DIM`, and
   `MAX_FULL_RES_PIXELS` for any read without a suitable overview. Refuse rasters
   above a size cap with no overviews (**Decide:** a cap, e.g. 20,000² without
   overviews). Use a short `GDAL_HTTP_TIMEOUT` (15 s) and `GDAL_HTTP_MAX_RETRY=1`.
6. **Limits per request and per client.** One own-URL warp at a time per client,
   a wall-clock cap per request (60 s), and a small rate limit (for example 30
   per hour per client).
7. **Log, don't keep.** Log the URL, host, client, bytes and seconds. Don't cache
   own-URL data beyond GDAL's in-memory HTTP cache, and don't add own URLs to
   the catalogue automatically.

## Tiers

| tier | who reaches it | own URLs |
|---|---|---|
| 0 (now) | you, through the tunnel | none; catalogue plus `vrt=` |
| 1 | you, through the tunnel | any https COG, under rules 1-7 (rule 4 by resolver check; the firewall can wait) |
| 2 | colleagues (behind auth, e.g. on its own small VM like the relay) | only hosts on an allowlist, plus rules 1-7 with the dedicated user and the egress firewall |
| 3 | anyone | not recommended; if ever, allowlist only, strict rate limits, no `url=` beyond allowlisted prefixes |

**One allowlist for both services.** The CORS relay
(`relay.ace-eco-stats.cloud.edu.au`) already reads an allowlist from
`/etc/cors-relay/hosts`, today NSIDC and Bremen sea ice. A tier-2 sandbox could
use the same file format: one host per line. A sensible start is the hosts the
catalogue already reads from (`data.source.coop`, `opentopography.s3.sdsc.edu`,
`gibs.earthdata.nasa.gov`, Esri and the Australian state map services), plus
any you add.

## How it would plug in

Own URLs can reuse the catalogue machinery the latency benchmark already used:
probe the URL into a one-row catalogue (`probe_one()`, `catalogue_flags()`),
then `warp_request(source = <id>, cat = <that row>)`. Every engine, the page and
`/compare` then work unchanged. The new pieces are:

- `own_source(url)`: rules 1, 4 and 5, returning the row or a clear refusal.
- An `allowed_drivers` path through the engines (rule 2): GDAL7 for rwarp's
  reads, `-if GTiff` for gdal-app, `--input-format` for gdal7-run. gdal-direct is
  already GDAL7.
- A credential-free GDAL context for those reads (rule 3).
- `url=` on `/warp`, `/plan` and `/compare`, and a field on the page.

## Decisions for the maintainer

1. Which tier first: **1** (just you, any https COG) is cheap and useful.
2. `http://` as well as `https://`?
3. GTiff only, or Zarr too (and when)?
4. The size cap for rasters without overviews.
5. For tier 2: where the service lives (its own VM, like the relay?), how
   colleagues sign in, and the allowlist.
6. Whether to move the service to a dedicated user now, even at tier 1. That's
   cheap insurance, given what's in `~/.Renviron`.
