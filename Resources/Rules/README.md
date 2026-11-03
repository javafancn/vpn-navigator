# Bundled initial Mainland China routing snapshots

IPv4:

Source: https://github.com/misakaio/chnroutes2/blob/master/chnroutes.txt
Upstream Git blob SHA: 5f97c3f9a8864a3f4fdd86b63bbe3e659388fe66
Retrieved: 2026-10-17 UTC
Data: unmodified upstream text, licensed under CC BY-SA 2.0.
License URI: https://creativecommons.org/licenses/by-sa/2.0/
Attribution: Misaka Network contributors and feed providers named in upstream README.

This bootstrap permits offline first use. The app validates it before caching,
then offers verified-format updates and local rule import. Country routes are
approximate and do not establish jurisdiction. See LICENSES/CHNROUTES2_NOTICE.txt.

IPv6 (`china-ipv6.txt`):

Source: https://ftp.apnic.net/stats/apnic/delegated-apnic-20261103
Retrieved: 2026-11-03 UTC
Upstream MD5: 7b3b630ee778a4533bfcfb4adba6a964 (matches APNIC's published checksum).
Seed SHA-256: 8aa585cc2ac005d709e0fb20fe679ae797149c966f26a5c1ab6151bb82da9533
Extracted 2,046 unique CN IPv6 allocated/assigned prefixes; canonicalized and
sorted, with no inferred ranges. The complete upstream had 89,637 data records.
The application seeds only missing families and preserves existing caches.
APNIC permits downloading and using these reports under its included conditions
of use; see LICENSES/APNIC_STATS_NOTICE.txt, which is included in the app.
