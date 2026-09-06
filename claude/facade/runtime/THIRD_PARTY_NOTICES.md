# Claude-only MCP runtime notices

This directory contains the exact runtime packages used by the Claude 21st
facade. Packages were obtained from the official npm registry with lifecycle
scripts disabled. License files shipped by each package are preserved beside
the package under node_modules/.

| Package | Version | License | Preserved license file |
|---|---:|---|---|
| @modelcontextprotocol/client | 2.0.0 | MIT | node_modules/@modelcontextprotocol/client/LICENSE |
| @modelcontextprotocol/core | 2.0.0 | MIT | node_modules/@modelcontextprotocol/core/LICENSE |
| @modelcontextprotocol/server | 2.0.0 | MIT | node_modules/@modelcontextprotocol/server/LICENSE |
| cross-spawn | 7.0.6 | MIT | node_modules/cross-spawn/LICENSE |
| eventsource | 3.0.7 | MIT | node_modules/eventsource/LICENSE |
| eventsource-parser | 3.1.1 | MIT | node_modules/eventsource-parser/LICENSE |
| isexe | 2.0.0 | ISC | node_modules/isexe/LICENSE |
| jose | 6.2.12 | MIT | node_modules/jose/LICENSE.md |
| path-key | 3.1.1 | MIT | node_modules/path-key/license |
| pkce-challenge | 5.0.1 | MIT | node_modules/pkce-challenge/LICENSE |
| shebang-command | 2.0.0 | MIT | node_modules/shebang-command/license |
| shebang-regex | 3.0.0 | MIT | node_modules/shebang-regex/license |
| which | 2.0.2 | ISC | node_modules/which/LICENSE |
| zod | 4.5.4 | MIT | node_modules/zod/LICENSE |

The facade source and the lock/provenance metadata are FTK-owned. The SDK and
transitive package contents are not edited manually.
